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

  -- * Tags
  , Tag
  , TagPool
  , newTagPool
  , getTag

  -- * Timeouts
  , Timeout
  , infiniteWait
  , noWait

  -- * Procedure calls
  , callAt
  , callTimeout
  , multicall
  , callResponse
  , callResponseIf
  , callResponseDefer
  , callResponseDeferIf
  , callForward
  , callResponseAsync

  -- * Server calls
  , whereisOrStart
  , whereisOrStartRemote

  -- * Remote call table
  , __remoteTable
  ) where

import Control.Distributed.Process
import Control.Distributed.Process.Global.Types
import Control.Distributed.Process.Global.Call
import Control.Distributed.Process.Global.Util hiding (__remoteTable)
import qualified Control.Distributed.Process.Global.Util (__remoteTable)
import Control.Distributed.Process.Global.Server hiding (__remoteTable)
import qualified Control.Distributed.Process.Global.Server (__remoteTable)
import Control.Distributed.Process.Global.Merge 

----------------------------------------------
-- * Remote table
----------------------------------------------

__remoteTable :: RemoteTable -> RemoteTable
__remoteTable = 
   Control.Distributed.Process.Global.Server.__remoteTable .
   Control.Distributed.Process.Global.Util.__remoteTable


