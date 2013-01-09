{-# LANGUAGE DeriveDataTypeable, TemplateHaskell #-}
module Control.Distributed.Process.Global.Util
  ( newTagPool
  , getTag

  , randomSleep

  , partitionByDifference
  , unionWithKeyM
  , mention
  , choose
  , goodResponse

  , showExceptions
  , ensureResult
  , UnexpectedConnectionFailure(..)
  ) where

import Data.Typeable (Typeable)
import Control.Distributed.Process.Global.Types
import Control.Concurrent.MVar
import Control.Distributed.Process
import Control.Distributed.Process.Internal.Closure.BuiltIn (seqCP)
import Control.Distributed.Process.Closure (remotable, mkClosure)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Platform
import Control.Exception (throwIO, SomeException, Exception)
import Prelude hiding (catch)
import Control.Monad (void)
import Control.Concurrent (myThreadId,threadDelay, throwTo)
import Data.Maybe (isJust, fromJust)
import System.Random (randomRIO)
import Data.Bits (shiftL)
import qualified Data.Map as M

----------------------------------------------
-- * Timeouts
----------------------------------------------

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

