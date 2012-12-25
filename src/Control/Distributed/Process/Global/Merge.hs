module Control.Distributed.Process.Global.Merge
  ( addNode
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Global.Types
import Control.Distributed.Process.Global.Util
import Control.Distributed.Process.Global.Server
import Control.Distributed.Process.Global.Call

import Data.List (nub, union)
import qualified Data.Map as M

----------------------------------------------
-- * Merging
----------------------------------------------

-- Merging two clusters requires synchronously
-- updating the state of all nodes. Therefore,
-- we need to acquire a global lock in both clusters.
-- This is the work of the dedicated locker process,
-- which is a worker of the global name server.
-- Once a lock has been achieved, each node's view
-- of the cluster must be updated: its list of
-- of known nodes, and its name registry.
-- The user process that calls addNode is known
-- as the  manager process, and is responsible
-- for submitting the merge request to the locker
-- and overseeing the merging of the name registry.
-- If this process dies, the merge is aborted.

-- | Merge the given node into the cluster of the
-- calling node. All nodes currently in a cluster
-- with the target node will also be merged. Names
-- registered with 'globalWhereis' will also be shared
-- with the new nodes. If the given node is already
-- in the current cluster or if merging fails, False
-- will be returned.
addNode :: NodeId -> TagPool -> Process Bool
addNode hisNid tag =
  do tag1 <- getTag tag
     myGns <- getLocalNameServer
     hisGns <- getRemoteNameServer hisNid
     self <- getSelfPid
     go self tag1 myGns hisGns
  where
     mergeNames namesa namesb =
        let merger name (pida,method) (pidb,_) =
              if pida==pidb 
                 then return $ Just (pida, method)
                 else case method of
                        ResolutionNotifyRandom ->
                          do send pidb (ResolutionNotification name (Just pida))
                             return $ Just (pida, method)
                        ResolutionNotifyBoth -> 
                          do send pidb (ResolutionNotification name Nothing)
                             send pida (ResolutionNotification name Nothing)
                             return Nothing
         in unionWithKeyM merger namesa namesb
     mergeKnown knowna knownb = nub $ union knowna knownb
     cancelLock locker request =
        do let msg = MergeCancelLock request
           tag3 <- getTag tag
           ret <- callAt locker msg tag3
           case ret of 
              Just True -> return True
              _ -> return False
     go _ _ _ Nothing = return False
     go self tag1 myGns (Just hisGns) =
       let request = MergeRequest {
                       mrOriginatingNameServer = myGns,
                       mrSecondaryNameServer = hisGns,
                       mrManager = self, 
                       mrTag = tag1}
        in do tag2 <- getTag tag
              ret <- multicall [myGns, hisGns] 
                        (MergeSubmitRequest request) 
                        tag2
                        infiniteWait
              case goodResponse ret of
                False -> return False
                True -> do tag4 <- getTag tag -- Both groups are now locked
                           states <- multicall [myGns, hisGns] MergeQueryState tag4 infiniteWait
                                 :: Process [Maybe ([GlobalNameServer], M.Map String (ProcessId, ResolutionMethod))]
                           res <- case states of
                             [Just (myKnown, myNames), Just (hisKnown, hisNames)] ->
                               let newKnown = mergeKnown myKnown hisKnown
                                in do newNames <- mergeNames myNames hisNames
                                      tag5 <- getTag tag
                                      _ <- multicall newKnown (MergeUpdateState newKnown newNames) tag5 infiniteWait :: Process [Maybe Bool]
                                      return True
                             _ -> return False -- TODO we've failed to merge state, what to do?
                           _ <- cancelLock myGns request
                           _ <- cancelLock hisGns request
                           return res

