{-# LANGUAGE DeriveDataTypeable #-}
module Control.Distributed.Process.Global.Types
  ( Timeout
  , TimeoutNotification(..)
  
  , Tag
  , TagPool

  , LockName
  , LockId
  , LockRequesterId

  , ResolutionNotification(..)
  , ResolutionMethod(..)
  , NodeDownNotification(..)

  , ClusterOperation(..)
  , RegisterSelf(..)

  , NameEffectuate(..)
  , NameWhereis(..)
  , NameOperation(..)
  , MergeRequest(..)
  , MergeSubmitRequest(..)
  , MergePleaseLock(..)
  , MergeCancelLock(..)
  , MergeQueryState(..)
  , MergeUpdateState(..)
  , LockOperation(..)
  , LockQueryOperation(..)

  , GlobalNameServer
  , GNSState(..)
  ) where

import Control.Applicative ((<$>),(<*>))
import qualified Data.Map as M (Map)
import Control.Distributed.Process (MonitorRef, ProcessId)
import Control.Concurrent.MVar (MVar)
import Data.Binary (Binary,get,put,putWord8,getWord8)
import Data.Typeable (Typeable)

----------------------------------------------
-- * Timeouts
----------------------------------------------

-- | A period of time to wait, or Nothing for
-- infinite waiting.
type Timeout = Maybe Int

-- | Send to a process when a timeout expires.
data TimeoutNotification = TimeoutNotification Tag
       deriving (Typeable)
instance Binary TimeoutNotification where
       get = fmap TimeoutNotification $ get
       put (TimeoutNotification n) = put n

----------------------------------------------
-- * Tags
----------------------------------------------

-- | Tags provide uniqueness for messages, so that they can be
-- matched with their response.
type Tag = Int

-- | Generates unique 'Tag' for messages and response pairs.
-- Each process that depends, directly or indirectly, on
-- the call mechanisms in "Control.Distributed.Process.Global.Call"
-- should have at most one TagPool on which to draw unique message
-- tags.
type TagPool = MVar Tag

----------------------------------------------
-- * Global name server messages
----------------------------------------------

-- | Queries known nodes at the given node (not including itself). 
-- Returns a [GlobalNameServer]
data ClusterOperation =
       ClusterGetKnown deriving Typeable
instance Binary ClusterOperation where
    put ClusterGetKnown = putWord8 0
    get = getWord8 >> return ClusterGetKnown

-- | Used internally in whereisOrStart. Send as (RegisterSelf,ProcessId).
data RegisterSelf = RegisterSelf deriving Typeable
instance Binary RegisterSelf where
  put _ = return ()
  get = return RegisterSelf

-- | Perform a registry update at the receiver node. Presumes that locking
-- is already taken care of. The String identifies the name. If the PID and ResolutionMethod
-- are omitted, the name is deleted. If only the ResolutionMethod is omitted, the
-- name is reregistered. Returns success as a Bool
data NameEffectuate = NameEffectuate String (Maybe ProcessId) (Maybe ResolutionMethod)
        deriving Typeable
instance Binary NameEffectuate where
   put (NameEffectuate a b c) = put a >> put b >> put c
   get = NameEffectuate <$> get <*> get <*> get

-- | Looks up the name in the global registry.
-- Returns (Maybe ProcessId)
data NameWhereis = NameWhereis String deriving Typeable
instance Binary NameWhereis where
    put (NameWhereis name) = put name
    get = NameWhereis <$> get 

-- | Initiates cluster locking and performs safe registry update.
-- Returns success as Bool
data NameOperation=
       NameRegister String ProcessId ResolutionMethod
     | NameUnregister String
     | NameReregister String ProcessId deriving Typeable
instance Binary NameOperation where
    put (NameRegister a b c) = putWord8 0 >> put a >> put b >> put c
    put (NameUnregister a) = putWord8 1 >> put a
    put (NameReregister a b) = putWord8 2 >> put a >> put b
    get = do a <- getWord8
             case a of
                0 -> NameRegister <$> get <*> get <*> get
                1 -> NameUnregister <$> get
                2 -> NameReregister <$> get <*> get
                _ -> error "NameOperation.get"

----------------------------------------------
-- * Global name server types
----------------------------------------------

-- | Identifies a PID of a node-unique name server process.
type GlobalNameServer = ProcessId

data GNSState = GNSState
    {
      gnsLocks :: M.Map LockName (LockRequesterId, [(ProcessId, MonitorRef)]),
      gnsRefs :: M.Map MonitorRef LockName,
      gnsKnown :: [(GlobalNameServer, MonitorRef)],
      gnsNames :: M.Map String (ProcessId, ResolutionMethod, MonitorRef),
      gnsNameRefs :: M.Map MonitorRef String,
      gnsRegistrar :: ProcessId,
      gnsLocker :: ProcessId
    }

----------------------------------------------
-- * Merge types
----------------------------------------------

-- | This is sent to the /losers/ in name resolution. If two different processes are registered
-- to the same name, then when their respective clusters are merged, at most one will remain
-- registered. How such conflicts are resolved in determined by the 'ResolutionMethod'
-- parameter when registering names.
data ResolutionNotification = ResolutionNotification String (Maybe ProcessId) deriving Typeable

instance Binary ResolutionNotification where
  put (ResolutionNotification a b) = put a >> put b
  get = ResolutionNotification <$> get <*> get

-- | Determines how conflicting name registrations are handled during cluster merges.
-- It's not possible for a single name to refer to two different PIDs, and all nodes
-- in a cluster must agree on the value of names. So if two clusters have different
-- values for the same name at most one will /win/.
-- If the resolution method is 'ResolutionNotifyRandom', one of the processes
-- will get this message, indicating that it is being unregistered, in favor of the given PID.
-- If the method is 'ResolutionNotifyBoth', both processes will get the message, and the name
-- will be unregistered.
data ResolutionMethod = 
        -- | One of the conflicting PIDs will be arbitrarily chosen as the /winner/,
        -- and will keep its registration. The other process will be unregistered
        -- and will be sent a 'ResolutionNotification' message containing the PID
        -- of the winner.
        ResolutionNotifyRandom
        -- | Both conflicting PIDs will be unregistered and both will be sent
        -- a 'ResolutionNotification'.
      | ResolutionNotifyBoth 
                      deriving (Typeable,Show)

instance Binary ResolutionMethod where
   put ResolutionNotifyRandom = putWord8 0
   put ResolutionNotifyBoth = putWord8 1
   get = do a <- getWord8
            case a of
               0 -> return ResolutionNotifyRandom 
               1 -> return ResolutionNotifyBoth
               _ -> error "ResolutionMethod.get"

data MergeRequest = 
   MergeRequest
    {
      mrOriginatingNameServer :: GlobalNameServer,
      mrSecondaryNameServer :: GlobalNameServer,
      mrManager :: ProcessId,
      mrTag :: Tag
    } deriving Eq

instance Binary MergeRequest where
  put (MergeRequest a b c d) = put a >> put b >> put c >> put d
  get = MergeRequest <$> get <*> get <*> get <*> get

-- | Sent to a process when its peer in the cluster has been
-- marked as disconnected, thus violating the principle of
-- a fully connected network. In response, the node should
-- stop communicating with it.
data NodeDownNotification = NodeDownNotification ProcessId deriving Typeable
instance Binary NodeDownNotification where
  put (NodeDownNotification a) = put a
  get = NodeDownNotification <$> get

----------------------------------------------
-- * Merge messages
----------------------------------------------

-- | Notify the locker of a new merge request.
-- Blocks until all nodes are locked. Returns success as Bool
data MergeSubmitRequest = MergeSubmitRequest MergeRequest deriving Typeable

-- | One locker signalling the other to ensure locking of its group. 
-- Returns success as Bool.
data MergePleaseLock = MergePleaseLock MergeRequest deriving Typeable

-- | After the merge is complete, the lockers will resume normal operation
-- after cancelling the locks. Returns succses as Bool
data MergeCancelLock = MergeCancelLock MergeRequest deriving Typeable

-- | Request known nodes and names from a given node. 
-- Returns ([GlobalNameServer], M.Map String (ProcessId, ResolutionMethod))
data MergeQueryState = MergeQueryState deriving Typeable

-- | Have merged node lists and names, update them at all new nodes
-- Returns sucess as Bool
data MergeUpdateState = MergeUpdateState [GlobalNameServer] (M.Map String (ProcessId, ResolutionMethod)) deriving Typeable

instance Binary MergeUpdateState where
  put (MergeUpdateState known names) = put known >> put names
  get = MergeUpdateState <$> get <*> get

instance Binary MergeQueryState where
  put MergeQueryState = return ()
  get = return MergeQueryState

instance Binary MergeSubmitRequest where
  put (MergeSubmitRequest a) = put a
  get = MergeSubmitRequest <$> get

instance Binary MergePleaseLock where
  put (MergePleaseLock a) = put a
  get = MergePleaseLock <$> get

instance Binary MergeCancelLock where
  put (MergeCancelLock a) = put a
  get = MergeCancelLock <$> get


----------------------------------------------
-- * Lock messages
----------------------------------------------

-- | Send as a tuple (LockOperation, LockRequester, LockName, ProcessId)
-- Returns success as Bool
data LockOperation = 
        SetLock
      | DeleteLock deriving Typeable
instance Binary LockOperation where
   put SetLock = putWord8 0
   put DeleteLock = putWord8 1
   get = do a<-getWord8
            case a of
              0 -> return SetLock
              1 -> return DeleteLock
              _ -> error "LockOperation.get"

-- | Send as a tuple (QueryLock, LockName)
-- Returns True if currently set
data LockQueryOperation =
        QueryLock deriving Typeable
instance Binary LockQueryOperation where
   put _ = return ()
   get = return QueryLock

----------------------------------------------
-- * Lock types
----------------------------------------------

-- | An arbitrary name identifying the resource to be locked.
type LockName = String

-- | The process or processes on whose behalf the lock is requested.
-- An attempt for a process to lock the same resource for a different
-- requester will fail.
type LockRequesterId = [ProcessId]

-- | Together, the 'LockName' and 'LockRequesterId' form the lock's identifier.
type LockId = (LockName, LockRequesterId)



