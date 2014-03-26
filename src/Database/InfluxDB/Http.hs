{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Database.InfluxDB.Http
  ( Config(..)
  , Credentials(..), rootCreds
  , Server(..), localServer
  , TimePrecision(..)
  , Database(..)
  , Series(..)
  -- , ScheduledDelete(..)
  , User(..)
  , Admin(..)

  -- * Writing Data

  -- ** Updating Points
  , post, postWithPrecision
  , SeriesT, ValueT
  , writeSeries
  , withSeries
  , writePoints

  -- ** Deleting Points
  -- *** One Time Deletes (not implemented)
  -- , deleteSeries
  -- *** Regularly Scheduled Deletes (not implemented)
  -- , getScheduledDeletes
  -- , addScheduledDelete
  -- , removeScheduledDelete

  -- * Querying Data
  , query
  , Stream(..)
  , queryChunked

  -- * Administration & Security
  -- ** Creating and Dropping Databases
  , listDatabases
  , createDatabase
  , dropDatabase

  -- ** Security
  -- *** Cluster admin
  , listClusterAdmins
  , addClusterAdmin
  , updateClusterAdminPassword
  , deleteClusterAdmin
  -- *** Database user
  , listDatabaseUsers
  , addDatabaseUser
  , updateDatabaseUserPassword
  , deleteDatabaseUser
  , grantAdminPrivilegeTo
  , revokeAdminPrivilegeFrom
  ) where

import Control.Applicative
import Control.Monad.Identity
import Control.Monad.Writer
import Data.DList (DList)
import Data.IORef (IORef)
import Data.Proxy
import Data.Text (Text)
import Data.Vector (Vector)
import Network.URI (escapeURIString, isAllowedInURI)
import Text.Printf (printf)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as BL
import qualified Data.DList as DL
import qualified Data.Text as T

import Control.Exception.Lifted (Handler(..))
import Control.Retry
import Data.Aeson ((.=))
import Data.Default.Class (Default(def))
import qualified Data.Aeson as A
import qualified Data.Aeson.Encode as AE
import qualified Data.Attoparsec as P
import qualified Network.HTTP.Client as HC

import Database.InfluxDB.Encode
import Database.InfluxDB.Types

data Config = Config
  { configCreds :: !Credentials
  , configServerPool :: IORef ServerPool
  }

rootCreds :: Credentials
rootCreds = Credentials
  { credsUser = "root"
  , credsPassword = "root"
  }

localServer :: Server
localServer = Server
  { serverHost = "localhost"
  , serverPort = 8086
  , serverSsl = False
  }

data TimePrecision
  = SecondsPrecision
  | MillisecondsPrecision
  | MicrosecondsPrecision

timePrecChar :: TimePrecision -> Char
timePrecChar SecondsPrecision = 's'
timePrecChar MillisecondsPrecision = 'm'
timePrecChar MicrosecondsPrecision = 'u'

-----------------------------------------------------------
-- Writing Data

post
  :: Config
  -> HC.Manager
  -> Database
  -> SeriesT IO a
  -> IO a
post config manager database =
  postGeneric config manager database Nothing

postWithPrecision
  :: Config
  -> HC.Manager
  -> Database
  -> TimePrecision
  -> SeriesT IO a
  -> IO a
postWithPrecision config manager database timePrec =
  postGeneric config manager database (Just timePrec)

postGeneric
  :: Config
  -> HC.Manager
  -> Database
  -> Maybe TimePrecision
  -> SeriesT IO a
  -> IO a
postGeneric Config {..} manager database timePrec write = do
  (a, series) <- runSeriesT write
  void $ httpLbsWithRetry configServerPool (makeRequest series) manager
  return a
  where
    makeRequest series = def
      { HC.method = "POST"
      , HC.requestBody = HC.RequestBodyLBS $ AE.encode series
      , HC.path = escapeString $ printf "/db/%s/series"
          (T.unpack databaseName)
      , HC.queryString = escapeString $ printf "u=%s&p=%s%s"
          (T.unpack credsUser)
          (T.unpack credsPassword)
          (maybe "" (printf "&time_precision=%c" . timePrecChar) timePrec :: String)
      }
    Database {databaseName} = database
    Credentials {..} = configCreds

newtype SeriesT m a = SeriesT (WriterT (DList Series) m a)
  deriving
    ( Functor, Applicative, Monad, MonadIO, MonadTrans
    , MonadWriter (DList Series)
    )

newtype ValueT p m a = ValueT (WriterT (DList (Vector Value)) m a)
  deriving
    ( Functor, Applicative, Monad, MonadIO, MonadTrans
    , MonadWriter (DList (Vector Value))
    )

runSeriesT :: Monad m => SeriesT m a -> m (a, [Series])
runSeriesT (SeriesT w) = do
  (a, series) <- runWriterT w
  return (a, DL.toList series)

-- runWrite :: Write a -> (a, [Series])
-- runWrite = runIdentity . runWriteT

writeSeries
  :: (Monad m, ToSeriesData a)
  => Text
  -- ^ Series name
  -> a
  -- ^ Series data
  -> SeriesT m ()
writeSeries name a = tell . DL.singleton $ Series
  { seriesName = name
  , seriesData = toSeriesData a
  }

withSeries
  :: forall m p. (Monad m, ToSeriesData p)
  => Text
  -- ^ Series name
  -> ValueT p m ()
  -> SeriesT m ()
withSeries name (ValueT w) = do
  (_, values) <- lift $ runWriterT w
  tell $ DL.singleton Series
    { seriesName = name
    , seriesData = SeriesData
        { seriesDataColumns = toSeriesColumns (Proxy :: Proxy p)
        , seriesDataPoints = values
        }
    }

writePoints
  :: (Monad m, ToSeriesData p)
  => p
  -> ValueT p m ()
writePoints = tell . DL.singleton . toSeriesPoints

-- TODO: Delete API hasn't been implemented in InfluxDB yet
--
-- deleteSeries
--   :: Config
--   -> HC.Manager
--   -> Series
--   -> IO ()
-- deleteSeries Config {..} manager =
--   error "deleteSeries: not implemented"
--
-- getScheduledDeletes
--   :: Config
--   -> HC.Manager
--   -> IO [ScheduledDelete]
-- getScheduledDeletes = do
--   error "getScheduledDeletes: not implemented"
--
-- addScheduledDelete
--   :: Config
--   -> HC.Manager
--   -> IO ScheduledDelete
-- addScheduledDelete =
--   error "addScheduledDeletes: not implemented"
--
-- removeScheduledDelete
--   :: Config
--   -> HC.Manager
--   -> ScheduledDeletes
--   -> IO ()
-- removeScheduledDelete =
--   error "removeScheduledDelete: not implemented"

-----------------------------------------------------------
-- Querying Data

query :: Config -> HC.Manager -> Database -> Text -> IO [Series]
query Config {..} manager database q = do
  response <- httpLbsWithRetry configServerPool request manager
  case A.decode (HC.responseBody response) of
    Nothing -> fail $ show response
    Just xs -> return xs
  where
    request = def
      { HC.path = escapeString $ printf "/db/%s/series"
          (T.unpack databaseName)
      , HC.queryString = escapeString $ printf "u=%s&p=%s&q=%s"
          (T.unpack credsUser)
          (T.unpack credsPassword)
          (T.unpack q)
      }
    Database {databaseName} = database
    Credentials {..} = configCreds

data Stream m a
  = Yield a (m (Stream m a))
  | Done

yield :: Monad m => a -> m (Stream m a) -> m (Stream m a)
yield a = return . Yield a

done :: Monad m => m (Stream m a)
done = return Done

responseStream :: A.FromJSON a => HC.BodyReader -> IO (Stream IO a)
responseStream body = readBody outer
  where
    readBody k = HC.brRead body >>= k
    outer payload
      | BS.null payload = done
      | otherwise = inner $ parseJson payload
    inner (P.Done leftover value) = case A.fromJSON value of
      A.Success a -> yield a $ if BS.null leftover
        then responseStream body
        else inner $ parseJson leftover
      A.Error message -> fail message
    inner (P.Partial k) = readBody (inner . k)
    inner (P.Fail _ _ message) = fail message
    parseJson = P.parse A.json

queryChunked
  :: Config
  -> HC.Manager
  -> Database
  -> Text
  -> (Stream IO Series -> IO a)
  -> IO a
queryChunked Config {..} manager database q f =
  withPool configServerPool request $ \request' ->
    HC.withResponse request' manager $ responseStream . HC.responseBody >=> f
  where
    request = def
      { HC.path = escapeString $ printf "/db/%s/series"
          (T.unpack databaseName)
      , HC.queryString = escapeString $ printf "u=%s&p=%s&q=%s&chunked=true"
          (T.unpack credsUser)
          (T.unpack credsPassword)
          (T.unpack q)
      }
    Database {databaseName} = database
    Credentials {..} = configCreds

-----------------------------------------------------------
-- Administration & Security

listDatabases :: Config -> HC.Manager -> IO [Database]
listDatabases Config {..} manager = do
  response <- httpLbsWithRetry configServerPool makeRequest manager
  case A.decode (HC.responseBody response) of
    Nothing -> fail $ show response
    Just xs -> return xs
  where
    makeRequest = def
      { HC.path = "/db"
      , HC.queryString = escapeString $ printf "u=%s&p=%s"
          (T.unpack credsUser)
          (T.unpack credsPassword)
      }
    Credentials {..} = configCreds

createDatabase :: Config -> HC.Manager -> Text -> IO Database
createDatabase Config {..} manager name = do
  void $ httpLbsWithRetry configServerPool makeRequest manager
  return Database
    { databaseName = name
    , databaseReplicationFactor = Nothing
    }
  where
    makeRequest = def
      { HC.method = "POST"
      , HC.requestBody = HC.RequestBodyLBS $ AE.encode $ A.object
          [ "name" .= name
          ]
      , HC.path = "/db"
      , HC.queryString = escapeString $ printf "u=%s&p=%s"
          (T.unpack credsUser)
          (T.unpack credsPassword)
      }
    Credentials {..} = configCreds

dropDatabase :: Config -> HC.Manager -> Database -> IO ()
dropDatabase Config {..} manager database =
  void $ httpLbsWithRetry configServerPool makeRequest manager
  where
    makeRequest = def
      { HC.method = "DELETE"
      , HC.path = escapeString $ printf "/db/%s"
          (T.unpack databaseName)
      , HC.queryString = escapeString $ printf "u=%s&p=%s"
          (T.unpack credsUser)
          (T.unpack credsPassword)
      }
    Database {databaseName} = database
    Credentials {..} = configCreds

listClusterAdmins
  :: Config
  -> HC.Manager
  -> IO [Admin]
listClusterAdmins Config {..} manager = do
  response <- httpLbsWithRetry configServerPool makeRequest manager
  case A.decode (HC.responseBody response) of
    Nothing -> fail $ show response
    Just xs -> return xs
  where
    makeRequest = def
      { HC.path = "/cluster_admins"
      , HC.queryString = escapeString $ printf "u=%s&p=%s"
          (T.unpack credsUser)
          (T.unpack credsPassword)
      }
    Credentials {..} = configCreds

addClusterAdmin
  :: Config
  -> HC.Manager
  -> Text
  -> IO Admin
addClusterAdmin Config {..} manager name = do
  void $ httpLbsWithRetry configServerPool makeRequest manager
  return Admin
    { adminUsername = name
    }
  where
    makeRequest = def
      { HC.requestBody = HC.RequestBodyLBS $ AE.encode $ A.object
          [ "name" .= name
          ]
      , HC.path = "/cluster_admins"
      , HC.queryString = escapeString $ printf "u=%s&p=%s"
          (T.unpack credsUser)
          (T.unpack credsPassword)
      }
    Credentials {..} = configCreds

updateClusterAdminPassword
  :: Config
  -> HC.Manager
  -> Admin
  -> Text
  -> IO ()
updateClusterAdminPassword Config {..} manager admin password =
  void $ httpLbsWithRetry configServerPool makeRequest manager
  where
    makeRequest = def
      { HC.method = "POST"
      , HC.requestBody = HC.RequestBodyLBS $ AE.encode $ A.object
          [ "password" .= password
          ]
      , HC.path = escapeString $ printf "/cluster_admins/%s"
          (T.unpack adminUsername)
      , HC.queryString = escapeString $ printf "u=%s&p=%s"
          (T.unpack credsUser)
          (T.unpack credsPassword)
      }
    Admin {adminUsername} = admin
    Credentials {..} = configCreds

deleteClusterAdmin
  :: Config
  -> HC.Manager
  -> Admin
  -> IO ()
deleteClusterAdmin Config {..} manager admin =
  void $ httpLbsWithRetry configServerPool makeRequest manager
  where
    makeRequest = def
      { HC.method = "DELETE"
      , HC.path = escapeString $ printf "/cluster_admins/%s"
          (T.unpack adminUsername)
      , HC.queryString = escapeString $ printf "u=%s&p=%s"
          (T.unpack credsUser)
          (T.unpack credsPassword)
      }
    Admin {adminUsername} = admin
    Credentials {..} = configCreds

listDatabaseUsers
  :: Config
  -> HC.Manager
  -> Text
  -> IO [User]
listDatabaseUsers Config {..} manager database = do
  response <- httpLbsWithRetry configServerPool makeRequest manager
  case A.decode (HC.responseBody response) of
    Nothing -> fail $ show response
    Just xs -> return xs
  where
    makeRequest = def
      { HC.path = escapeString $ printf "/db/%s/users"
          (T.unpack database)
      , HC.queryString = escapeString $ printf "u=%s&p=%s"
          (T.unpack credsUser)
          (T.unpack credsPassword)
      }
    Credentials {..} = configCreds

addDatabaseUser
  :: Config
  -> HC.Manager
  -> Database
  -> Text
  -> IO User
addDatabaseUser Config {..} manager database name = do
  void $ httpLbsWithRetry configServerPool makeRequest manager
  return User
    { userName = name
    }
  where
    makeRequest = def
      { HC.requestBody = HC.RequestBodyLBS $ AE.encode $ A.object
          [ "name" .= name
          ]
      , HC.path = escapeString $ printf "/db/%s/users"
          (T.unpack databaseName)
      , HC.queryString = escapeString $ printf "u=%s&p=%s"
          (T.unpack credsUser)
          (T.unpack credsPassword)
      }
    Database {databaseName} = database
    Credentials {..} = configCreds

deleteDatabaseUser
  :: Config
  -> HC.Manager
  -> Database
  -> User
  -> IO ()
deleteDatabaseUser config manager database user =
  void $ httpLbsWithRetry (configServerPool config) request manager
  where
    request = (makeRequestFromDatabaseUser config database user)
      { HC.method = "DELETE"
      }

updateDatabaseUserPassword
  :: Config
  -> HC.Manager
  -> Database
  -> User
  -> Text
  -> IO ()
updateDatabaseUserPassword config manager database user password =
  void $ httpLbsWithRetry (configServerPool config) request manager
  where
    request = (makeRequestFromDatabaseUser config database user)
      { HC.method = "POST"
      , HC.requestBody = HC.RequestBodyLBS $ AE.encode $ A.object
          [ "password" .= password
          ]
      }

grantAdminPrivilegeTo
  :: Config
  -> HC.Manager
  -> Database
  -> User
  -> IO ()
grantAdminPrivilegeTo config manager database user =
  void $ httpLbsWithRetry (configServerPool config) request manager
  where
    request = (makeRequestFromDatabaseUser config database user)
      { HC.method = "POST"
      , HC.requestBody = HC.RequestBodyLBS $ AE.encode $ A.object
          [ "admin" .= True
          ]
      }

revokeAdminPrivilegeFrom
  :: Config
  -> HC.Manager
  -> Database
  -> User
  -> IO ()
revokeAdminPrivilegeFrom config manager database user =
  void $ httpLbsWithRetry (configServerPool config) request manager
  where
    request = (makeRequestFromDatabaseUser config database user)
      { HC.method = "POST"
      , HC.requestBody = HC.RequestBodyLBS $ AE.encode $ A.object
          [ "admin" .= False
          ]
      }

makeRequestFromDatabaseUser
  :: Config
  -> Database
  -> User
  -> HC.Request
makeRequestFromDatabaseUser Config {..} database user = def
  { HC.path = escapeString $ printf "/db/%s/users/%s"
      (T.unpack databaseName)
      (T.unpack userName)
  , HC.queryString = escapeString $ printf "u=%s&p=%s"
      (T.unpack credsUser)
      (T.unpack credsPassword)
  }
  where
    Database {databaseName} = database
    User {userName} = user
    Credentials {..} = configCreds

-----------------------------------------------------------

httpLbsWithRetry
  :: IORef ServerPool
  -> HC.Request
  -> HC.Manager
  -> IO (HC.Response BL.ByteString)
httpLbsWithRetry pool request manager =
  withPool pool request $ \request' ->
    HC.httpLbs request' manager

withPool
  :: IORef ServerPool
  -> HC.Request
  -> (HC.Request -> IO a)
  -> IO a
withPool pool request f =
  recovering defaultRetrySettings handlers $ do
    server <- activeServer pool
    f $ makeRequest server
  where
    makeRequest Server {..} = request
      { HC.host = escapeText serverHost
      , HC.port = serverPort
      , HC.secure = serverSsl
      }
    handlers =
      [ Handler $ \e -> case e of
          HC.InternalIOException _ -> do
            failover pool
            return True
          _ -> return False
      ]

defaultRetrySettings :: RetrySettings
defaultRetrySettings = RetrySettings
  { numRetries = limitedRetries 5
  , backoff = True
  , baseDelay = 50
  }

escapeText :: Text -> BS.ByteString
escapeText = escapeString . T.unpack

escapeString :: String -> BS.ByteString
escapeString = BS8.pack . escapeURIString isAllowedInURI
