module Main where

import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Global
import Control.Distributed.Process.Global.Util (mention)

import Control.Distributed.Process.Platform hiding (__remoteTable)
import Control.Distributed.Process.Platform.Call
import Control.Distributed.Process.Platform.Test
import Control.Distributed.Process.Platform.Time

import Control.Exception (SomeException)
import Control.Concurrent.MVar
import Control.Concurrent (threadDelay, myThreadId, throwTo)

import Network.Transport (Transport)
import Network.Transport.TCP

import Prelude hiding (catch)

import Test.HUnit (Assertion)
import Test.Framework (Test, defaultMain, testGroup)
import Test.Framework.Providers.HUnit (testCase)

myRemoteTable :: RemoteTable
myRemoteTable = Control.Distributed.Process.Global.__remoteTable initRemoteTable

multicallTest :: Transport -> Assertion
multicallTest transport =
  do node1 <- newLocalNode transport myRemoteTable
     tryRunProcess node1 $
       do pid1 <- whereisOrStart "server1" server1
          _ <- whereisOrStart "server2" server2
          pid2 <- whereisOrStart "server2" server2
          tag <- newTagPool

          -- First test: expect positives answers from both processes
          tag1 <- getTag tag
          result1 <- multicall [pid1,pid2] mystr tag1 infiniteWait
          case result1 of
            [Just reversed, Just doubled] |
                 reversed == reverse mystr && doubled == mystr ++ mystr -> return ()
            _ -> error "Unmatched"

          -- Second test: First process works, second thread throws an exception
          tag2 <- getTag tag
          [Just 10, Nothing] <- multicall [pid1,pid2] (5::Int) tag2 infiniteWait :: Process [Maybe Int]

          -- Third test: First process exceeds time limit, second process is still dead
          tag3 <- getTag tag
          [Nothing, Nothing] <- multicall [pid1,pid2] (23::Int) tag3 (Just 1000000) :: Process [Maybe Int]
          return ()
    where server1 = receiveWait [callResponse (\str -> mention (str::String) (return (reverse str,())))]  >>
                    receiveWait [callResponse (\i -> mention (i::Int) (return (i*2,())))] >>
                    receiveWait [callResponse (\i -> liftIO (threadDelay 2000000) >> mention (i::Int) (return (i*10,())))]
          server2 = receiveWait [callResponse (\str -> mention (str::String) (return (str++str,())))] >>
                    receiveWait [callResponse (\i -> error "barf" >> mention (i::Int) (return (i :: Int,())))]
          mystr = "hello"

registrationErrors :: Transport -> Assertion
registrationErrors transport =
  do node1 <- newLocalNode transport myRemoteTable
     tryRunProcess node1 $
       do tag <- newTagPool
          self <- getSelfPid

          -- New registration ok
          True <- globalRegister tag "pid1" self ResolutionNotifyRandom
 
          -- Fails: name already registered
          False <- globalRegister tag "pid1" self ResolutionNotifyRandom

          -- Unregistering existing name ok
          True <- globalUnregister tag "pid1" 

          -- Registering previously unregistered name ok
          True <- globalRegister tag "pid1" self ResolutionNotifyRandom

          -- Fails: unregistering non-existing name 
          False <- globalUnregister tag "pid2" 

          -- Fails: cannot reregister non-existing name
          False <- globalReregister tag "pid2" self
          newpid <- spawnLocal (liftIO $ threadDelay 1000000)

          -- Explicit reregistration ok
          True <- globalReregister tag "pid1" newpid
          return ()

registrationVisibility :: Transport -> Assertion
registrationVisibility transport =
  do node1 <- newLocalNode transport myRemoteTable
     node2 <- newLocalNode transport myRemoteTable
     tryRunProcess node1 $
       do tag <- newTagPool
          True <- addNode (localNodeId node2) tag
          pid1 <- spawnLocal (liftIO $ threadDelay 2000000)
          True <- globalRegister tag "pid1" pid1 ResolutionNotifyRandom
          Just _ <- globalWhereis tag "pid1"
          return ()
     tryRunProcess node2 $
       do tag <- newTagPool
          Just thepid <- globalWhereis tag "pid1"
          True <- globalUnregister tag "pid1"
          True <- globalRegister tag "pid2" thepid ResolutionNotifyRandom
          return ()
     tryRunProcess node1 $
       do tag <- newTagPool
          Nothing <- globalWhereis tag "pid1"
          Just _ <- globalWhereis tag "pid2"
          return ()

clusterTest1 :: Transport -> Assertion
clusterTest1 transport = 
  do node1 <- newLocalNode transport myRemoteTable
     node2 <- newLocalNode transport myRemoteTable
     node3 <- newLocalNode transport myRemoteTable
     tryRunProcess node2 $
       do tag <- newTagPool
          True <- addNode (localNodeId node3) tag
          return ()
     tryRunProcess node1 $
       do tag <- newTagPool
          True <- addNode (localNodeId node2) tag
          pid1 <- spawnLocal (liftIO $ threadDelay 500000)
          pid2 <- spawnLocal (liftIO $ threadDelay 2000000)
          True <- globalRegister tag "pid1" pid1 ResolutionNotifyRandom
          True <- globalRegister tag "pid2" pid2 ResolutionNotifyRandom
          False <- globalRegister tag "pid2" pid2 ResolutionNotifyRandom
          return ()
     threadDelay 1000000
     tryRunProcess node3 $
       do tag <- newTagPool
          [_,_] <- getKnownNameServers tag
          Nothing <- globalWhereis tag "pid1"
          Just _ <- globalWhereis tag "pid2"
          return ()

clusterTest2 :: Transport -> Assertion
clusterTest2 transport = 
  do node1 <- newLocalNode transport myRemoteTable
     node2 <- newLocalNode transport myRemoteTable
     node3 <- newLocalNode transport myRemoteTable
     mv1 <- newEmptyMVar
     mv2 <- newEmptyMVar
     mv3 <- newEmptyMVar
     tryForkProcess node1 $
       do tag <- newTagPool
          _ <- addNode (localNodeId node1) tag
          _ <- addNode (localNodeId node2) tag
          _ <- addNode (localNodeId node3) tag
          liftIO $ putMVar mv1 ()
     tryForkProcess node2 $
       do tag <- newTagPool
          _ <- addNode (localNodeId node1) tag
          _ <- addNode (localNodeId node2) tag
          _ <- addNode (localNodeId node3) tag
          liftIO $ putMVar mv2 ()
     tryForkProcess node3 $
       do tag <- newTagPool
          _ <- addNode (localNodeId node1) tag
          _ <- addNode (localNodeId node2) tag
          _ <- addNode (localNodeId node3) tag
          liftIO $ putMVar mv3 ()
     tryRunProcess node1 $
       do tag <- newTagPool
          liftIO $ takeMVar mv1
          liftIO $ takeMVar mv2
          liftIO $ takeMVar mv3
          [_,_] <- getKnown tag
          return ()

collisionTest :: Transport -> Assertion
collisionTest transport = 
  do node1 <- newLocalNode transport myRemoteTable
     node2 <- newLocalNode transport myRemoteTable
     mv1 <- newEmptyMVar
     mv2 <- newEmptyMVar
     mv3 <- newEmptyMVar
     mv4 <- newEmptyMVar
     tryForkProcess node1 $
       do tag <- newTagPool
          self <- getSelfPid
          True <- globalRegister tag "pid1" self ResolutionNotifyBoth
          True <- globalRegister tag "pid2" self ResolutionNotifyBoth
          liftIO $ putMVar mv1 ()
          Just (ResolutionNotification "pid1" Nothing) <- expectTimeout 5000000
          liftIO $ takeMVar mv3
          liftIO $ putMVar mv1 ()
          return ()
     tryForkProcess node2 $
       do tag <- newTagPool
          self <- getSelfPid
          True <- globalRegister tag "pid1" self ResolutionNotifyBoth
          True <- globalRegister tag "pid3" self ResolutionNotifyBoth
          liftIO $ putMVar mv2 ()
          Just (ResolutionNotification "pid1" Nothing) <- expectTimeout 5000000
          liftIO $ takeMVar mv4
          liftIO $ putMVar mv2 ()
          return ()
     takeMVar mv1
     takeMVar mv2
     tryRunProcess node1 $
       do tag <- newTagPool
          True <- addNode (localNodeId node2) tag

          -- pid1 is deleted due to conflict
          Nothing <- globalWhereis tag "pid1"

          -- pid2 and pid3 are merged intact
          Just _ <- globalWhereis tag "pid2"
          Just _ <- globalWhereis tag "pid3"
          return ()
     putMVar mv3 ()
     putMVar mv4 ()
     takeMVar mv1
     takeMVar mv2

tests :: Transport -> [Test]
tests transport = 
  [ 
    testGroup "Basic features" [
        testCase "multicallTest"               (multicallTest               transport),
        testCase "clusterTest1"                (clusterTest1                transport),
        testCase "clusterTest2"                (clusterTest2                transport),
        testCase "registrationErrors"          (registrationErrors          transport),
        testCase "registrationVisibility"      (registrationVisibility      transport),
        testCase "collisionTest"               (collisionTest               transport)
      ]
  ]

main :: IO ()
main =
  do Right transport <- createTransport "127.0.0.1" "8080" defaultTCPParameters
     defaultMain (tests transport)
     threadDelay 1000000

