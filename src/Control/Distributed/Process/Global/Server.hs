{-# LANGUAGE TemplateHaskell #-}
module Control.Distributed.Process.Global.Server 
  ( getLocalNameServer
  , getRemoteNameServer

  , globalWhereis
  , globalRegister
  , globalUnregister
  , globalReregister
  
  , getKnown
  , getKnownNameServers
  , transKnown
 
  , queryLock
  , setLockKnown
  , setLock
  , setLockOpt
  , delLock

  , __remoteTable
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Closure (mkClosure,remotable)
import Control.Distributed.Process.Global.Types
import Control.Distributed.Process.Global.Util

import Control.Distributed.Process.Platform hiding (__remoteTable)
import Control.Distributed.Process.Platform.Call
import Control.Distributed.Process.Platform.Time

import Control.Applicative ((<$>))
import Data.List (find, delete, sort, (\\))
import qualified Data.Map as M
import Data.Maybe (isJust,fromJust)
import Control.Monad (when, void, forM, forM_)

----------------------------------------------
-- * Names
----------------------------------------------

-- | A cluster-global equivalent of 'whereis'. If the
-- name isn't registered, Nothing will be returned.
globalWhereis :: TagPool -> String -> Process (Maybe ProcessId)
globalWhereis tag name =
  do gns <- getLocalNameServer
     tag1 <- getTag tag
     ensureResult $ callAt gns (NameWhereis name) tag1


-- | A cluster-global equivalent of 'register'. Registered names
-- are synchronously shared with all nodes in the cluster, and
-- given to new nodes as they enter the cluster. Set values can 
-- be retrieved with a call to 'globalWhereis'. Lookups are always
-- local and therefore fast; registration, however, requires acquiring
-- a cluster lock and therefore shouldn't be done too often. If the
-- given name is already registered, False will be returned.
-- The 'ResolutionMethod' parameter determines how conflicts are handled
-- when two clusters merge, when they have different values for the
-- same name.
globalRegister :: TagPool -> String -> ProcessId -> ResolutionMethod -> Process Bool
globalRegister tag name pid res =
  do gns <- getLocalNameServer
     tag1 <- getTag tag
     ensureResult $ callAt gns (NameRegister name pid res) tag1

-- | A cluster-global equivalent of 'unregister'. Removes a previously
-- registered name. If the name isn't already registered, False is
-- returned.
globalUnregister :: TagPool -> String -> Process Bool
globalUnregister tag name =
  do gns <- getLocalNameServer
     tag1 <- getTag tag
     ensureResult $ callAt gns (NameUnregister name) tag1

-- | A cluster-global equivalent of 'reregister'. Changes the
-- value of a previously registered name. If the name isn't already
-- registered, False is returned.
globalReregister :: TagPool -> String -> ProcessId -> Process Bool
globalReregister tag name pid =
  do gns <- getLocalNameServer
     tag1 <- getTag tag
     ensureResult $ callAt gns (NameReregister name pid) tag1


----------------------------------------------
-- * Cluster operations
----------------------------------------------

-- | Returns all nodes currently in the cluster.
getKnown :: TagPool -> Process [NodeId]
getKnown tag = (map processNodeId) <$> getKnownNameServers tag

-- | Ask the local name server for the list known nodes in the cluster,
-- excluding the one it's called on
getKnownNameServers :: TagPool -> Process [GlobalNameServer]
getKnownNameServers tag =
  do gns <- getLocalNameServer
     tag1 <- getTag tag
     ensureResult $ callAt gns ClusterGetKnown tag1

-- | Acquires a global cluster lock and executes the given function
-- During its execution, the cluster is fixed, so no new nodes will be
-- added or global variables changed
transKnown :: TagPool -> ([GlobalNameServer] -> Process a) -> Process a
transKnown tag fun =
  do self <- getSelfPid
     let lid = (name, [self])
     go lid
  where name = globalLockName
        infiniteRetries = Nothing
        go lid =
          bracket (fmap fromJust $ setLockKnown [] lid tag infiniteRetries)
          (\locks -> delLock locks lid tag)
          fun


----------------------------------------------
-- * Locking
----------------------------------------------

globalLockName :: LockName
globalLockName = "?GLOBAL"

-- | Returns true if the given lock is set on the given node,
queryLock :: LockName -> GlobalNameServer -> TagPool -> Process Bool
queryLock llname pid tag = 
  do tag1 <- getTag tag
     ret <- callAt pid msg tag1
     case ret of
       Nothing -> return False
       Just islocked -> return islocked
   where
    msg = (QueryLock, llname)
                

-- | Applies the global across all known nodes in the cluster
setLockKnown :: [GlobalNameServer] -> LockId -> TagPool -> Maybe Int -> Process (Maybe [GlobalNameServer])
setLockKnown extras name tag retries = setLockKnown' extras name tag retries 0

setLockKnown' :: [GlobalNameServer] -> LockId -> TagPool -> Maybe Int -> Int -> Process (Maybe [GlobalNameServer])
setLockKnown' extras name tag retries times =
  do known <- getKnownNameServers tag
     gns <- getLocalNameServer
     let allNodes = gns:known
     case sort allNodes of
       [] -> return Nothing
       (boss:therest) -> 
          do let phase1 = [boss]
             res <- setLock phase1 name tag infiniteWait oneTry
             case res of
                 True -> 
                   do let phase2 = delete boss extras
                      res2 <- setLock phase2 name tag infiniteWait oneTry
                      case res2 of
                        True ->
                          do let phase3 = therest \\ (phase1++phase2)
                             res3 <- setLockUpdate phase3 known
                             case res3 of
                                True -> return $ Just $ phase3 ++ phase2 ++ phase1
                                False -> do _ <- delLock (phase1++phase2) name tag
                                            again retries times $ setLockKnown' extras name tag
                        False ->
                          do _ <- delLock phase1 name tag
                             again retries times $ setLockKnown' extras name tag
                 False -> 
                   again retries times $ setLockKnown' extras name tag
    where
     again Nothing timesx f =  liftIO (randomSleep timesx) >> f Nothing (timesx+1)
     again (Just 0) _ _ = return Nothing
     again (Just n) timesx f =  liftIO (randomSleep timesx) >> f (Just $ n-1) (timesx+1)
     oneTry = Just 0
     setLockUpdate who known =
         do res <- setLock who name tag infiniteWait oneTry
            case res of
               True -> do knownNow <- getKnownNameServers tag
                          let ares = knownNow \\ known == []
                          when (not ares) --TODO ? this line is not here in global.erl
                              (void $ delLock who name tag)
                          return ares
               False -> return False

trySetLockOpt :: [GlobalNameServer] -> LockId -> TagPool -> Timeout -> Process Bool
trySetLockOpt [] _ _ _ = return True
trySetLockOpt somenodes name tag time =
  let (boss:therest) = sort somenodes
   in do res <- setLock [boss] name tag time (Just 0)
         case res of
            True -> 
               do res2 <- setLock therest name tag time (Just 0)
                  case res2 of
                     True -> return True
                     False -> do _ <- delLock [boss] name tag
                                 return False
            False -> return False

-- | Sets locks on the given nodes with retries. If the calling process dies, the lock will be released.
-- If the lock is already set with a different requester, the attempt to lock will be rejected and
-- False will be returned. If the lock is already locked with the same requester, the calling process
-- will be added to the lock's holders.
setLock :: [GlobalNameServer] -> LockId -> TagPool -> Timeout -> Maybe Int -> Process Bool
setLock = setLockVar trySetLock

-- | A slightly optimized version of 'setLock'.
--  Sets locks on the given nodes, starting with the least-valued process ID, to avoid unnecessary contention
setLockOpt :: [GlobalNameServer] -> LockId -> TagPool -> Timeout -> Maybe Int -> Process Bool
setLockOpt = setLockVar trySetLockOpt

-- | Applies retries to any lock-setting primitive
setLockVar :: ([GlobalNameServer] -> LockId -> TagPool -> Timeout -> Process Bool) -> 
               [GlobalNameServer] -> LockId -> TagPool -> Timeout -> Maybe Int -> Process Bool
setLockVar tryLock nodes name tag time retries =
    go retries 0
  where 
    dec Nothing = Nothing
    dec (Just i) = Just (i-1)
    go myretries times =
      do res <- tryLock nodes name tag time
         case res of
           True -> return True
           False | myretries == Just 0 -> return False
           _ -> 
             do liftIO $ randomSleep times
                go (dec myretries) (times+1)

-- | Delete the lock on the given nodes as held by the calling process.
-- If another process also holds the same lock, it won't be released.
delLock :: [GlobalNameServer] -> LockId -> TagPool -> Process Bool
delLock nodes (llname,llrequestor) tag = 
  do self <- getSelfPid
     let msg = (DeleteLock, llrequestor, llname, self)
     tag1 <- getTag tag
     _ <- multicall nodes msg tag1 noWait :: Process [Maybe Bool]
     return True

trySetLock :: [GlobalNameServer] -> LockId -> TagPool -> Timeout -> Process Bool
trySetLock nodes (llname,llrequestor) tag time =
  do self <- getSelfPid
     let msg = (SetLock, llrequestor, llname, self)
     tag1 <- getTag tag
     res <- multicall nodes msg tag1 time
     case positiveResponders res of
       allpositives | allpositives == nodes -> 
              return True
       positives -> 
              do tag2 <- getTag tag
                 _ <- multicall positives (DeleteLock, llrequestor, llname, self) tag2 noWait :: Process [Maybe Bool]
                 return False
       where positiveResponders res = 
                map fst $ filter ((==)(Just True)  . snd) (zip nodes res)

----------------------------------------------
-- * Global locker
----------------------------------------------

-- | Process for managing two-cluster locking necessary for merging clusters.
globalLocker :: ProcessId -> Process ()
globalLocker gns =
  let go (tag, mergeRequests) =
        let receiveMaybeTimeout = 
               case mergeRequests of
                 [] -> fmap Just . receiveWait
                 _ -> receiveTimeout 1000000
         in do ret <- receiveMaybeTimeout
                 [
                 callResponseDefer   (\(MergeSubmitRequest request) responder -> 
                                          case request of
                                             request' | mrSecondaryNameServer request' == 
                                                        mrOriginatingNameServer request' ||
                                                        request' `elem` map fst mergeRequests ->
                                                        do responder False
                                                           return (tag, mergeRequests)  
                                                      | otherwise -> return (tag, (request,responder):mergeRequests)),
                 callResponseDeferIf (\(MergePleaseLock request) -> isJust $ find ((==)request . fst) mergeRequests )
                                     (\(MergePleaseLock request) sender -> 
                                         do let lid = mergeLockId request
                                            known <- getKnownNameServers tag
                                            case isValidRequest known request of
                                                False -> sender False >> return (tag, subtractRequest request mergeRequests)
                                                True ->
                                                  do locked <- setLockKnown [] lid tag (Just 0)
                                                     case locked of
                                                       Just allLocked -> 
                                                         do sender True -- say okay to other locker
                                                            let responder = snd $ fromJust $ find ((==)request . fst) mergeRequests
                                                            responder True -- say okay to manager
                                                            blockUntilCancel request
                                                            _ <- delLock allLocked lid tag
                                                            return (tag, subtractRequest request mergeRequests)
                                                       Nothing -> sender False >> return (tag,mergeRequests) )
                 ]
               case ret of
                  Nothing -> do isset <- queryLock globalLockName gns tag
                                case isset of
                                   True -> go (tag,mergeRequests)
                                   False -> select (tag,mergeRequests) >>= go
                  Just newstate -> go newstate
   in do link gns
         tag <- newTagPool
         go (tag, [])
     where isValidRequest known (MergeRequest {mrOriginatingNameServer=origin,
                                   mrSecondaryNameServer=second}) =
                  origin `notElem` (gns:known) ||
                  second `notElem` (gns:known)
           subtractRequest req reqlist = filter ((/=)req . fst) reqlist
           blockUntilCancel request =
              do managerref <- monitor (mrManager request)
                 othersideref <- monitor (otherSide request)
                 receiveWait
                   [ callResponseIf (\(MergeCancelLock arequest) -> arequest == request)
                                    (\(MergeCancelLock _) -> return (True, ())),
                     matchIf (\(ProcessMonitorNotification aref _ _) -> aref == managerref ||
                                                                        aref == othersideref)
                             (\(ProcessMonitorNotification _ _ _) -> return ())
                   ]
                 unmonitor managerref >> unmonitor othersideref
           otherSide :: MergeRequest -> GlobalNameServer
           otherSide m | mrOriginatingNameServer m == gns = mrSecondaryNameServer m
                       | otherwise = mrOriginatingNameServer m
           select :: (TagPool,[(MergeRequest,Bool -> Process ())]) -> Process (TagPool,[(MergeRequest,Bool -> Process ())])
           select lockerState@(tag,mergeRequests) =
              do known <- getKnownNameServers tag
                 mrequest <- liftIO $ choose mergeRequests
                 case mrequest of
                   Nothing -> return (tag, mergeRequests)
                   Just (request, responder) | isValidRequest known request -> 
                     do let lid = mergeLockId request
                        locked <- setLockKnown [otherSide request] lid tag (Just 0)
                        case locked of
                          Nothing -> return lockerState
                          Just allLocked -> let msg = MergePleaseLock request
                                     in do tag1 <- getTag tag
                                           res <- callAt (otherSide request) msg tag1 -- TODO quit if manager dies
                                           case res of
                                             Just True -> 
                                                do responder True
                                                   blockUntilCancel request
                                                   _ <- delLock allLocked lid tag
                                                   return (tag, subtractRequest request mergeRequests)
                                             _ -> do _ <- delLock allLocked lid tag
                                                     return lockerState
                   Just (badrequest, badresponder) ->
                     do badresponder False
                        return (tag, subtractRequest badrequest mergeRequests)

mergeLockId :: MergeRequest -> LockId
mergeLockId MergeRequest {mrOriginatingNameServer=origin, mrSecondaryNameServer=second} =
   (globalLockName, sort [origin, second])

----------------------------------------------
-- * Global registrar
----------------------------------------------

-- | Process for executing cluster operations on registered names. This process
-- will hold the lock necessary for synchronously updating all process's registry.
globalRegistrar :: ProcessId -> Process ()
globalRegistrar gns =
  let go tag =
        receiveWait
        [

           -- Handle name operations forwarded from main server process
           callResponse (\msg ->
             case msg of
               NameRegister name pid method -> 
                  do gw <- globalWhereis tag name
                     case gw of
                        Just _ -> return (False,())
                        Nothing ->
                           transKnown tag $ \allGns -> 
                              do tag1 <- getTag tag
                                 ret <- multicall allGns 
                                           (NameEffectuate name (Just pid) (Just method))
                                           tag1
                                           infiniteWait :: Process [Maybe Bool]
                                 return (goodResponse ret,())
               NameUnregister name -> 
                  do gw <- globalWhereis tag name
                     case gw of
                       Nothing -> return (False,())
                       Just _ ->
                         transKnown tag $ \allGns -> 
                            do tag1 <- getTag tag
                               ret <- multicall allGns
                                       (NameEffectuate name Nothing Nothing)
                                       tag1
                                       infiniteWait :: Process [Maybe Bool]
                               return (goodResponse ret,())
               NameReregister name pid ->
                  do gw <- globalWhereis tag name
                     case gw of
                       Nothing -> return (False,())
                       Just _ ->
                         transKnown tag $ \allGns ->
                           do tag1 <- getTag tag
                              ret <- multicall allGns
                                       (NameEffectuate name (Just pid) Nothing)
                                       tag1
                                       infiniteWait :: Process [Maybe Bool]
                              return (goodResponse ret,())                  
              ),
           matchUnknown (return ())
        ] >> go tag
   in do link gns
         tag <- newTagPool
         go tag

----------------------------------------------
-- * Global name server
----------------------------------------------

globalNameServerName :: String
globalNameServerName = "GlobalNameServer"

-- | Main global name server
startGlobalNameServer :: () -> Process ()
startGlobalNameServer _ =
     do self <- getSelfPid
        grpid <- spawnLocal (globalRegistrar self)
        link grpid        
        glpid <- spawnLocal (globalLocker self)
        link glpid
        let initialGNSState = 
                          GNSState {
                             gnsLocks = M.empty,
                             gnsRefs = M.empty,
                             gnsKnown = [],
                             gnsNames = M.empty,
                             gnsNameRefs = M.empty,
                             gnsRegistrar = grpid,
                             gnsLocker = glpid}
        globalNameServerLoop initialGNSState

globalNameServerLoop :: GNSState -> Process a
globalNameServerLoop gnsState@GNSState 
                         {gnsLocks = gnsLocks,
                          gnsRefs = gnsRefs,
                          gnsKnown = gnsKnown,
                          gnsRegistrar = gnsRegistrar,
                          gnsLocker = gnsLocker,
                          gnsNames = gnsNames,
                          gnsNameRefs = gnsNameRefs} = 
  receiveWait
    [ 
      -- Process down
      matchIf (\(ProcessMonitorNotification ref _pid _) -> M.member ref gnsRefs || 
                                                          M.member ref gnsNameRefs ||
                                                          ref `elem` (map snd gnsKnown))
              (\(ProcessMonitorNotification ref _pid _) -> 
                 let 
                     newKnown = filter ((/=)ref . snd) gnsKnown

                     newNameRefs = M.delete ref gnsNameRefs
                     newNames =
                       case M.lookup ref gnsNameRefs of
                          Nothing -> gnsNames
                          Just name ->
                            M.delete name gnsNames

                     newRefs = M.delete ref gnsRefs
                     newLocks = 
                       case M.lookup ref gnsRefs of
                          Nothing -> gnsLocks
                          Just lock ->
                            case M.lookup lock gnsLocks of
                              Nothing -> gnsLocks
                              Just (lrid,pds) ->
                                 let newpds = filter (\(_,r) -> r /= ref) pds
                                  in if null newpds
                                        then M.delete lock gnsLocks
                                        else M.insert lock (lrid,newpds) gnsLocks
                  in -- TODO add node to disconnectedNodes list, or call (as yet nonexistent) forceDisconnect function
                     do case find ((==)ref . snd) gnsKnown of
                           Nothing -> return () 
                           Just (gnspid,_) -> mapM_ (\(p,_) -> send p (NodeDownNotification gnspid)) gnsKnown -- TODO this message is ignored for now
                        return gnsState {gnsLocks=newLocks, gnsRefs=newRefs,
                                      gnsNames=newNames, gnsNameRefs=newNameRefs,gnsKnown=newKnown}),

      -- Merging
      callForward (\msg -> mention (msg::MergeSubmitRequest) (gnsLocker, gnsState)),
      callForward (\msg -> mention (msg::MergePleaseLock) (gnsLocker, gnsState)),
      callForward (\msg -> mention (msg::MergeCancelLock) (gnsLocker, gnsState)),
      callResponse (\(MergeUpdateState newKnown newNames) -> 
          do self <- getSelfPid
             let (knownUnchanged, knownRemoved, knownAdded) = 
                     partitionByDifference (\(p1,_) (p2) -> p1==p2) gnsKnown (delete self newKnown)
             forM_ knownRemoved $ \(_,ref) -> unmonitor ref
             knownAdded' <- forM knownAdded $ \p -> 
                  do ref <- monitor p
                     return (p,ref)
             let myKnown = knownUnchanged ++ knownAdded'

             let loop (mp,mprefs) [] = return (mp,mprefs)
                 loop (mp,mprefs) ((name,(pid,meth)):xs) =
                   case M.lookup name mp of
                     Nothing -> 
                       do ref <- monitor pid
                          loop (M.insert name (pid,meth,ref) mp,
                                M.insert ref name mprefs) xs
                     Just (samepid,_,_) | samepid == pid -> 
                       loop (mp,mprefs) xs
                     Just (_oldpid,_,oldref) ->
                       do unmonitor oldref
                          ref <- monitor pid
                          loop (M.insert name (pid,meth,ref) mp,
                               M.delete oldref (M.insert ref name mprefs)) xs
             let loop2 (mp,mprefs) [] = return (mp,mprefs)
                 loop2 (mp,mprefs) ((name,(_pid,_meth,ref)):xs) =
                   case M.lookup name newNames of
                     Just _ -> loop2 (mp,mprefs) xs
                     Nothing -> do unmonitor ref
                                   loop2 (M.delete name mp, M.delete ref mprefs) xs

             -- Insert or update existing entries
             (myNames,myNameRefs) <- loop (gnsNames,gnsNameRefs) (M.toList newNames)

             -- Delete and unregister items not appearing in newNames that are in gnsNames
             (myNames',myNameRefs') <- loop2 (myNames,myNameRefs) (M.toList myNames)
             return (True,gnsState {gnsKnown = myKnown, gnsNames = myNames', gnsNameRefs = myNameRefs'})),
      callResponse (\MergeQueryState -> 
          do self <- getSelfPid
             let allKnown = self:map fst gnsKnown
                 allNames =  fmap (\(pid,method,_) -> (pid,method)) gnsNames
                 result :: ([GlobalNameServer], M.Map String (ProcessId, ResolutionMethod))
                 result = (allKnown, allNames)
             return (result,gnsState)),

      -- Cluster operations
      callResponse (\msg ->
        case msg of
          ClusterGetKnown -> return (map fst gnsKnown,gnsState)),

      -- Name operations
      callResponse (\(NameWhereis name) -> 
            case M.lookup name gnsNames of
               Just (pid, _, _) -> return (Just pid, gnsState)
               Nothing -> return (Nothing, gnsState)),
      callForward (\msg -> mention (msg::NameOperation) (gnsRegistrar, gnsState)),
      callResponse (\msg -> 
         case msg of
           (NameEffectuate name Nothing Nothing) ->
               case M.lookup name gnsNames of
                 Just (_, _, ref) ->
                    do unmonitor ref
                       return $ (True,gnsState {gnsNames = M.delete name gnsNames,
                                                gnsNameRefs = M.delete ref gnsNameRefs})
                 Nothing ->
                    return (False, gnsState)
           (NameEffectuate name (Just pid) Nothing) ->
               case M.lookup name gnsNames of
                 Just (_, _, oldref) ->
                    do unmonitor oldref
                       newref <- monitor pid
                       return $ (True,gnsState {gnsNames = M.adjust (\(_,m,_) -> (pid,m,newref)) name gnsNames,
                                                gnsNameRefs = M.delete oldref (M.insert newref name gnsNameRefs)})
                 Nothing ->
                    return (False, gnsState)
           (NameEffectuate name (Just pid) (Just method)) ->
               case M.lookup name gnsNames of
                 Just _ ->
                    return $ (False,gnsState)
                 Nothing ->
                    do ref <- monitor pid
                       return (True, gnsState {gnsNames = M.insert name (pid,method,ref) gnsNames,
                                               gnsNameRefs = M.insert ref name gnsNameRefs})
           _ -> return (False, gnsState)),


      -- Lock operations
      callResponse (\msg ->
        case msg of
          (QueryLock, llname) ->
              case M.lookup llname gnsLocks of
                Just _ -> return (True,gnsState)
                Nothing -> return (False,gnsState)),
      callResponse (\msg -> 
        case msg of
          (SetLock, requestor, name, pid) -> 
              let (okay, pids) = 
                     case M.lookup name gnsLocks of 
                        Nothing -> (True, [])
                        Just (lrid,pds) | lrid==requestor -> (True, pds)
                        _ -> (False,[])
               in if okay
                     then if pid `elem` (map fst pids)
                             then return (True,gnsState)
                             else do ref <- monitor pid
                                     let newLocks = M.insert name (requestor, (pid,ref) : pids) gnsLocks
                                         newRefs = M.insert ref name gnsRefs
                                     return (True,gnsState {gnsLocks = newLocks, gnsRefs = newRefs})
                     else return (False,gnsState)
          (DeleteLock, requestor, name, pid) ->
               case M.lookup name gnsLocks of
                  Just (lrid, pds) | lrid==requestor ->
                     let mres = find (\(pd,_) -> pd == pid) pds
                      in case mres of 
                           Nothing -> return (True, gnsState)
                           Just res@(_,ref) -> 
                                do unmonitor ref
                                   let newpds = delete res pds
                                       newLocks = if null newpds
                                                     then M.delete name gnsLocks
                                                     else M.insert name (requestor,newpds) gnsLocks
                                       newRefs = M.delete ref gnsRefs
                                    in return (True,gnsState {gnsLocks = newLocks, gnsRefs = newRefs})
                  _ -> return (True,gnsState)
            ),

      -- Ignore other
      matchUnknown (return gnsState)
    ] >>= globalNameServerLoop


----------------------------------------------
-- * Starting and finding the global name server
----------------------------------------------

getLocalNameServer :: Process ProcessId
getLocalNameServer = whereisOrStart globalNameServerName (startGlobalNameServer ())

$(remotable ['startGlobalNameServer])

getRemoteNameServer :: NodeId -> Process (Maybe ProcessId)
getRemoteNameServer nid = whereisOrStartRemote nid globalNameServerName ($(mkClosure 'startGlobalNameServer) ())

