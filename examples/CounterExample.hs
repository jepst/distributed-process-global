module Main where

-- This program provides a version of the venerable counter server example, wherein
-- a central server process stores a value that can be queried and updated remotely.
-- We use Global's RPC mechanism, though, which safely handles cases when the server
-- dies and and automatically provides a response, with no explicit send. It also
-- allows user functions to find the PID of process by name only.

import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Global
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Control.Distributed.Process.Global.Util (ensureResult)
import Control.Concurrent (threadDelay)
import Control.Monad (replicateM_)

myRemoteTable :: RemoteTable
myRemoteTable = Control.Distributed.Process.Global.__remoteTable initRemoteTable

-- | Our server. Accepts messages as strings for simplicity.
getCounterPid :: Process ProcessId
getCounterPid = whereisOrStart "counter" (counter 0)
  where counter :: Int -> Process a
        counter value =
          receiveWait
           [
             callResponse (\msg ->
               case msg of
                 "query" -> return (value,value)
                 "increment" -> return (value,value+1)
                 "reset" -> return (value,0))
           ] >>= counter

-- | Queries current value of this node's counter, doesn't change it
queryCounter :: TagPool -> Process Int
queryCounter tag = counterMessage tag "query"

-- | Increments counter, returns old value
incrementCounter :: TagPool -> Process Int
incrementCounter tag = counterMessage tag "increment"

-- | Resets counter to zero, returns old value
resetCounter :: TagPool -> Process Int
resetCounter tag = counterMessage tag "reset"

counterMessage :: (Serializable a, Serializable b) => TagPool -> a -> Process b
counterMessage tag msg =
  do tag1 <- getTag tag
     counterpid <- getCounterPid
     ensureResult $ callAt counterpid msg tag1

test :: Process ()
test = 
  do tag <- newTagPool
     queryCounter tag >>= explain "Querying counter"
     incrementCounter tag >>= explain "Incrementing counter"
     incrementCounter tag >>= explain "Incrementing counter again"
     queryCounter tag >>= explain "Querying again"
     replicateM_ 500 (incrementCounter tag) >> liftIO (putStrLn "Incrementing a lot")
     resetCounter tag >>= explain "Resetting counter"
     queryCounter tag >>= explain "Querying again"
   where explain txt num =
              liftIO $ putStrLn $ txt ++": "++show num

main :: IO ()
main =
  do Right transport <- createTransport "127.0.0.1" "8080" defaultTCPParameters
     node <- newLocalNode transport myRemoteTable
     runProcess node test
     threadDelay 1000000

