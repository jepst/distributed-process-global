module Control.Distributed.Process.Global 
  ( 
    -- * Cluster operations
    addNode

  , ResolutionMethod(..)
  , ResolutionNotification(..)
  , globalWhereis
  , globalRegister
  , globalUnregister
  , globalReregister

  -- * Locks
  , GlobalNameServer
  , LockName
  , LockRequesterId
  , LockId
  , queryLock
  , setLockKnown
  , setLock
  , setLockOpt
  , delLock
  , transKnown
  , getKnown
  , getKnownNameServers

  -- * Remote call table
  , __remoteTable
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Global.Types
import Control.Distributed.Process.Global.Server hiding (__remoteTable)
import qualified Control.Distributed.Process.Global.Server (__remoteTable)
import Control.Distributed.Process.Global.Merge

import Control.Distributed.Process.Platform hiding (__remoteTable)
import qualified Control.Distributed.Process.Platform (__remoteTable)

----------------------------------------------
-- * Remote table
----------------------------------------------

__remoteTable :: RemoteTable -> RemoteTable
__remoteTable = 
   Control.Distributed.Process.Global.Server.__remoteTable .
   Control.Distributed.Process.Platform.__remoteTable
