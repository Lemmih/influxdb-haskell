{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
module Database.InfluxDB.Types
  ( -- * Series, columns and data points
    Series(..)
  , seriesColumns
  , seriesPoints
  , SeriesData(..)
  , Column
  , Value(..)

  -- * Data types for HTTP API
  , Credentials(..)
  , Server(..)
  , Database(..)
  , User(..)
  , Admin(..)
  , Ping(..)
  , Interface
  , ShardSpace(..)

  -- * Server pool
  , ServerPool
  , serverRetryPolicy
  , serverRetrySettings
  , newServerPool
  , newServerPoolWithRetryPolicy
  , newServerPoolWithRetrySettings
  , activeServer
  , failover

  -- * Exceptions
  , InfluxException(..)
  , jsonDecodeError
  , seriesDecodeError
  ) where

import Control.Applicative (empty)
import Control.Exception (Exception, throwIO)
import Data.Data (Data)
import Data.IORef
import Data.Int (Int64)
import Data.Monoid ((<>))
import Data.Sequence (Seq, ViewL(..), (|>))
import Data.Text (Text)
import Data.Typeable (Typeable)
import Data.Vector (Vector)
import Data.Word (Word32)
import GHC.Generics (Generic)
import qualified Data.Sequence as Seq

import Control.Retry (RetryPolicy(..), limitRetries, exponentialBackoff)
import Data.Aeson ((.=), (.:))
import Data.Aeson.TH
import qualified Data.Aeson as A

import Database.InfluxDB.Types.Internal (stripPrefixOptions)

#if MIN_VERSION_aeson(0, 7, 0)
import Data.Scientific
#else
import Data.Attoparsec.Number
#endif

-----------------------------------------------------------
-- Compatibility for older GHC

#if __GLASGOW_HASKELL__ < 706
import Control.Exception (evaluate)

atomicModifyIORef' :: IORef a -> (a -> (a, b)) -> IO b
atomicModifyIORef' ref f = do
    b <- atomicModifyIORef ref $ \x ->
      let (a, b) = f x
      in (a, a `seq` b)
    evaluate b
#endif
-----------------------------------------------------------

-- | A series consists of name, columns and points. The columns and points are
-- expressed in a separate type 'SeriesData'.
data Series = Series
  { seriesName :: {-# UNPACK #-} !Text
  -- ^ Series name
  , seriesData :: {-# UNPACK #-} !SeriesData
  -- ^ Columns and data points in the series
  } deriving (Typeable, Generic)

-- | Convenient accessor for columns.
seriesColumns :: Series -> Vector Column
seriesColumns = seriesDataColumns . seriesData

-- | Convenient accessor for points.
seriesPoints :: Series -> [Vector Value]
seriesPoints = seriesDataPoints . seriesData

instance A.ToJSON Series where
  toJSON Series {..} = A.object
    [ "name" .= seriesName
    , "columns" .= seriesDataColumns
    , "points" .= seriesDataPoints
    ]
    where
      SeriesData {..} = seriesData

instance A.FromJSON Series where
  parseJSON (A.Object v) = do
    name <- v .: "name"
    columns <- v .: "columns"
    points <- v .: "points"
    return Series
      { seriesName = name
      , seriesData = SeriesData
          { seriesDataColumns = columns
          , seriesDataPoints = points
          }
      }
  parseJSON _ = empty

-- | 'SeriesData' consists of columns and points.
data SeriesData = SeriesData
  { seriesDataColumns :: Vector Column
  , seriesDataPoints :: [Vector Value]
  } deriving (Eq, Show, Typeable, Generic)

type Column = Text

-- | An InfluxDB value represented as a Haskell value.
data Value
  = Int !Int64
  | Float !Double
  | String !Text
  | Bool !Bool
  | Null
  deriving (Eq, Show, Data, Typeable, Generic)

instance A.ToJSON Value where
  toJSON (Int n) = A.toJSON n
  toJSON (Float d) = A.toJSON d
  toJSON (String xs) = A.toJSON xs
  toJSON (Bool b) = A.toJSON b
  toJSON Null = A.Null

instance A.FromJSON Value where
  parseJSON (A.Object o) = fail $ "Unexpected object: " ++ show o
  parseJSON (A.Array a) = fail $ "Unexpected array: " ++ show a
  parseJSON (A.String xs) = return $ String xs
  parseJSON (A.Bool b) = return $ Bool b
  parseJSON A.Null = return Null
  parseJSON (A.Number n) = return $! numberToValue
    where
#if MIN_VERSION_aeson(0, 7, 0)
      numberToValue
        -- If the number is larger than Int64, it must be
        -- a float64 (Double in Haskell).
        | n > maxInt = Float $ toRealFloat n
        | e < 0 = Float $ realToFrac n
        | otherwise = Int $ fromIntegral $ coefficient n * 10 ^ e
        where
          e = base10Exponent n
#if !MIN_VERSION_scientific(0, 3, 0)
          toRealFloat = realToFrac
-- scientific
#endif
#else
      numberToValue = case n of
        I i
          -- If the number is larger than Int64, it must be
          -- a float64 (Double in Haskell).
          | i > maxInt -> Float $ fromIntegral i
          | otherwise -> Int $ fromIntegral i
        D d -> Float d
-- aeson
#endif
      maxInt = fromIntegral (maxBound :: Int64)

-----------------------------------------------------------

-- | User credentials.
data Credentials = Credentials
  { credsUser :: !Text
  , credsPassword :: !Text
  } deriving (Show, Typeable, Generic)

-- | Server location.
data Server = Server
  { serverHost :: !Text
  -- ^ Hostname or IP address
  , serverPort :: !Int
  , serverSsl :: !Bool
  -- ^ SSL is enabled or not in the server side
  } deriving (Show, Typeable, Generic)

-- | Non-empty set of server locations. The active server will always be used
-- until any HTTP communications fail.
data ServerPool = ServerPool
  { serverActive :: !Server
  -- ^ Current active server
  , serverBackup :: !(Seq Server)
  -- ^ The rest of the servers in the pool.
  , serverRetryPolicy :: !RetryPolicy
  } deriving (Typeable, Generic)

{-# DEPRECATED serverRetrySettings "Use serverRetryPolicy instead" #-}
serverRetrySettings :: ServerPool -> RetryPolicy
serverRetrySettings = serverRetryPolicy

newtype Database = Database
  { databaseName :: Text
  } deriving (Show, Typeable, Generic)

-- | User
data User = User
  { userName :: Text
  , userIsAdmin :: Bool
  } deriving (Show, Typeable, Generic)

-- | Administrator
newtype Admin = Admin
  { adminName :: Text
  } deriving (Show, Typeable, Generic)

newtype Ping = Ping
  { pingStatus :: Text
  } deriving (Show, Typeable, Generic)

type Interface = Text

data ShardSpace = ShardSpace
  { shardSpaceDatabase :: Maybe Text
  , shardSpaceName :: Text
  , shardSpaceRegex :: Text
  , shardSpaceRetentionPolicy :: Text
  , shardSpaceShardDuration :: Text
  , shardSpaceReplicationFactor :: Word32
  , shardSpaceSplit :: Word32
  } deriving (Show, Typeable, Generic)

-----------------------------------------------------------
-- Server pool manipulation

-- | Create a non-empty server pool. You must specify at least one server
-- location to create a pool.
newServerPool :: Server -> [Server] -> IO (IORef ServerPool)
newServerPool = newServerPoolWithRetrySettings defaultRetryPolicy
  where
    defaultRetryPolicy = limitRetries 5 <> exponentialBackoff 50

newServerPoolWithRetryPolicy
  :: RetryPolicy -> Server -> [Server] -> IO (IORef ServerPool)
newServerPoolWithRetryPolicy retryPolicy active backups =
  newIORef ServerPool
    { serverActive = active
    , serverBackup = Seq.fromList backups
    , serverRetryPolicy = retryPolicy
    }

{-# DEPRECATED newServerPoolWithRetrySettings
  "Use newServerPoolWithRetryPolicy instead" #-}
newServerPoolWithRetrySettings
  :: RetryPolicy -> Server -> [Server] -> IO (IORef ServerPool)
newServerPoolWithRetrySettings = newServerPoolWithRetryPolicy

-- | Get a server from the pool.
activeServer :: IORef ServerPool -> IO Server
activeServer ref = do
  ServerPool { serverActive } <- readIORef ref
  return serverActive

-- | Move the current server to the backup pool and pick one of the backup
-- server as the new active server. Currently the scheduler works in
-- round-robin fashion.
failover :: IORef ServerPool -> IO ()
failover ref = atomicModifyIORef' ref $ \pool@ServerPool {..} ->
  case Seq.viewl serverBackup of
    EmptyL -> (pool, ())
    active :< rest -> (newPool, ())
      where
        newPool = pool
          { serverActive = active
          , serverBackup = rest |> serverActive
          }

-----------------------------------------------------------
-- Exceptions

data InfluxException
  = JsonDecodeError String
  | SeriesDecodeError String
  deriving (Show, Typeable)

instance Exception InfluxException

jsonDecodeError :: String -> IO a
jsonDecodeError = throwIO . JsonDecodeError

seriesDecodeError :: String -> IO a
seriesDecodeError = throwIO . SeriesDecodeError

-----------------------------------------------------------
-- Aeson instances

deriveFromJSON (stripPrefixOptions "database") ''Database
deriveFromJSON (stripPrefixOptions "admin") ''Admin
deriveFromJSON (stripPrefixOptions "user") ''User
deriveFromJSON (stripPrefixOptions "ping") ''Ping
deriveFromJSON (stripPrefixOptions "shardSpace") ''ShardSpace
