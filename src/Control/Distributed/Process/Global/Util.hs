{-# LANGUAGE DeriveDataTypeable, TemplateHaskell #-}
module Control.Distributed.Process.Global.Util
  ( newTagPool
  , getTag

  , timeout
  , infiniteWait
  , noWait

  , randomSleep

  , partitionByDifference
  , unionWithKeyM
  , mention
  , choose
  , goodResponse

  , showExceptions
  , ensureResult
  , UnexpectedConnectionFailure(..)
  
  , whereisOrStart
  , whereisOrStartRemote
  
  , __remoteTable
  ) where

import Data.Typeable (Typeable)
import Control.Distributed.Process.Global.Types
import Control.Concurrent.MVar
import Control.Distributed.Process
import Control.Distributed.Process.Internal.Closure.BuiltIn (seqCP)
import Control.Distributed.Process.Closure (remotable, mkClosure)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Exception (throwIO, SomeException, Exception)
import Prelude hiding (catch)
import Control.Monad (void)
import Control.Concurrent (myThreadId,threadDelay, throwTo)
import Data.Maybe (isJust, fromJust)
import System.Random (randomRIO)
import Data.Bits (shiftL)
import qualified Data.Map as M

----------------------------------------------
-- * Tags
----------------------------------------------

-- | Create a new per-process source of unique
-- message identifiers.
newTagPool :: Process TagPool
newTagPool = liftIO $ newMVar 0

-- | Extract a new identifier from a 'TagPool'.
getTag :: TagPool -> Process Tag
getTag tp = liftIO $ modifyMVar tp (\tag -> return (tag+1,tag))

----------------------------------------------
-- * Timeouts
----------------------------------------------

infiniteWait :: Timeout
infiniteWait = Nothing

noWait :: Timeout
noWait = Just 0

timeout :: Int -> Tag -> ProcessId -> Process ()
timeout time tag p =
  void $ spawnLocal $ 
               do liftIO $ threadDelay time
                  send p (TimeoutNotification tag)

-- | Delay a random amount of time, which grows as we encounter more failures
randomSleep :: Int -> IO ()
randomSleep times =
   let maxdelay = max (quarterSecond `shiftL` times) maxest
    in do delay <- randomRIO (0, maxdelay)
          threadDelay delay
   where quarterSecond = 250000 
         maxest = quarterSecond * 4 * 8

----------------------------------------------
-- * Utility
----------------------------------------------

-- | Given a list of /old/ values and /new/ values, and a function to compare them,
-- produces lists of values that have remained, values that have been removed,
-- and values have been added.
--
-- >>> partitionByDifference (==) [1,2,3] [1,2]
-- ([1,2],[3],[])
--
-- >>> partitionByDifference (==) [1,2,3] [1,2,4]
-- ([1,2],[3],[4])
partitionByDifference :: (a -> b -> Bool) -> [a] -> [b] -> ([a], [a], [b])
partitionByDifference equal oldlist newlist =
  (unchanged, removed, added)
  where unchanged = filter (\a -> myelem equal a newlist) oldlist
        removed = filter (\a -> not $ myelem equal a newlist) oldlist
        added = filter (\b -> not $ myelem (flip equal) b oldlist) newlist

        myelem _eq _a [] = False
        myelem eq a (b:_) | a `eq` b = True
        myelem eq a (_:bs) = myelem eq a bs

-- | A monadic form of 'unionWithKey'
unionWithKeyM :: (Monad m, Ord k) => (k -> a -> a -> m (Maybe a)) -> M.Map k a -> M.Map k a -> m (M.Map k a)
unionWithKeyM f a b =
      go a (M.toList b)
    where
      go themap [] = return themap
      go themap ((key,val):xs) =
         case M.lookup key themap of
           Nothing -> go (M.insert key val themap) xs
           Just oldval -> 
              do ret <- f key oldval val
                 case ret of
                   Nothing -> go (M.delete key themap) xs
                   Just newval -> go (M.insert key newval themap) xs

mention :: a -> b -> b
mention _a b = b

-- | Randomly choose an item from the list
choose :: [a] -> IO (Maybe a)
choose [] = return Nothing
choose lst = do n <- randomRIO (0, length lst - 1)
                return $ Just $ lst !! n

-- | An alternative to 'matchIf' that allows both predicate and action
-- to be expressed in one parameter.
matchCond :: (Serializable a) => (a -> Maybe (Process b)) -> Match b
matchCond cond = 
   let v n = (isJust n, fromJust n)
       res = v . cond
    in matchIf (fst . res) (snd . res)

showExceptions :: Process a -> Process a
showExceptions proc =
  proc `catch` (\a -> do say $ show (a::SomeException)
                         liftIO $ throwIO a)

data UnexpectedConnectionFailure = UnexpectedConnectionFailure deriving (Show,Typeable)

instance Exception UnexpectedConnectionFailure

ensureResult :: Process (Maybe a) -> Process a
ensureResult proc =
   do res <- proc
      case res of
         Just a -> return a
         Nothing -> liftIO $ throwIO UnexpectedConnectionFailure

goodResponse :: [Maybe Bool] -> Bool
goodResponse [] = True
goodResponse (Just True : xs) = goodResponse xs
goodResponse _ = False


----------------------------------------------
-- * Generic servers
----------------------------------------------

-- | Returns the pid of the process that has been registered 
-- under the given name. This refers to a local, per-node registration,
-- not global registration. If that name is unregistered, a process
-- is started. This is a handy way to start per-node named servers.
whereisOrStart :: String -> Process () -> Process ProcessId
whereisOrStart name proc =
  do mpid <- whereis name
     case mpid of
       Just pid -> return pid
       Nothing -> 
         do caller <- getSelfPid
            pid <- spawnLocal $ 
                 do self <- getSelfPid
                    register name self
                    send caller (RegisterSelf,self)
                    () <- expect
                    proc
            ref <- monitor pid
            ret <- receiveWait
               [ matchIf (\(ProcessMonitorNotification aref _ _) -> ref == aref)
                         (\(ProcessMonitorNotification _ _ _) -> return Nothing),
                 matchIf (\(RegisterSelf,apid) -> apid == pid)
                         (\(RegisterSelf,_) -> return $ Just pid)
               ]
            case ret of
              Nothing -> whereisOrStart name proc
              Just somepid -> 
                do unmonitor ref
                   send somepid ()
                   return somepid

registerSelf :: (String, ProcessId) -> Process ()
registerSelf (name,target) =
  do self <- getSelfPid
     register name self
     send target (RegisterSelf, self)
     () <- expect
     return ()

$(remotable ['registerSelf])

-- | A remote equivalent of 'whereisOrStart'. It deals with the
-- node registry on the given node, and the process, if it needs to be started,
-- will run on that node. If the node is inaccessible, Nothing will be returned.
whereisOrStartRemote :: NodeId -> String -> Closure (Process ()) -> Process (Maybe ProcessId)
whereisOrStartRemote nid name proc =
     do mRef <- monitorNode nid
        whereisRemoteAsync nid name
        res <- receiveWait 
          [ matchIf (\(WhereIsReply label _) -> label == name)
                    (\(WhereIsReply _ mPid) -> return (Just mPid)),
            matchIf (\(NodeMonitorNotification aref _ _) -> aref == mRef)
                    (\(NodeMonitorNotification _ _ _) -> return Nothing)
          ]
        case res of
           Nothing -> return Nothing
           Just (Just pid) -> unmonitor mRef >> return (Just pid)
           Just Nothing -> 
              do self <- getSelfPid
                 sRef <- spawnAsync nid ($(mkClosure 'registerSelf) (name,self) `seqCP` proc)    
                 ret <- receiveWait [
                      matchIf (\(NodeMonitorNotification ref _ _) -> ref == mRef)
                              (\(NodeMonitorNotification _ _ _) -> return Nothing),
                      matchIf (\(DidSpawn ref _) -> ref==sRef )
                              (\(DidSpawn _ pid) -> 
                                  do pRef <- monitor pid
                                     receiveWait
                                       [ matchIf (\(RegisterSelf, apid) -> apid == pid)
                                                 (\(RegisterSelf, _) -> do unmonitor pRef
                                                                           send pid ()
                                                                           return $ Just pid),
                                         matchIf (\(NodeMonitorNotification aref _ _) -> aref == mRef)
                                                 (\(NodeMonitorNotification _aref _ _) -> return Nothing),
                                         matchIf (\(ProcessMonitorNotification ref _ _) -> ref==pRef)
                                                 (\(ProcessMonitorNotification _ _ _) -> return Nothing)
                                       ] )
                      ]
                 unmonitor mRef
                 case ret of
                   Nothing -> whereisOrStartRemote nid name proc
                   Just pid -> return $ Just pid 

