{-# LANGUAGE KindSignatures    #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Applicative       (liftA3)
import           Control.Exception         (catch, throw)
import           Control.Monad.IO.Class    (liftIO)
import           Control.Monad.Morph       (hoist)
import           Control.Monad.Trans.Class (lift)
import           Data.Aeson                (decode)
import           Data.Bool                 (bool)
import qualified Data.ByteString           as BS
import qualified Data.ByteString.Lazy      as LBS
import           Data.Functor              (void)
import qualified Data.IntMap               as M
import           Data.Semigroup            ((<>))
import qualified Data.Set                  as Set
import           Data.Text                 (Text)
import           Data.Text.Encoding        (decodeUtf8)
import           Data.Text.IO              (hPutStrLn)
import           GHC.Word                  (Word16)
import           Network.HTTP.Types.Status (statusCode)
import           System.Directory          (removeFile)
import           System.IO                 (stderr)
import           System.IO.Error           (isDoesNotExistError)

import           Hedgehog                  (Callback (..), Command (Command),
                                            Gen, HTraversable (htraverse),
                                            Property, PropertyT, assert,
                                            executeSequential, forAll, property,
                                            (===))
import qualified Hedgehog.Gen              as Gen
import qualified Hedgehog.Range            as Range
import qualified Network.Wai.Test          as WT
import           Test.Hspec.Wai            (WaiSession, get, post,
                                            runWaiSession, shouldRespondWith)
import           Test.Tasty                (defaultMain)
import           Test.Tasty.Hedgehog       (testProperty)

import           FirstApp.AppM             (Env (Env))
import           FirstApp.DB               (initDB)
import           FirstApp.Main             (app)
import           FirstApp.Types            (Conf (Conf),
                                            DBFilePath (DBFilePath),
                                            Port (Port), dbFilePath)

main :: IO ()
main =  do
  rmOkMissing dbPath
  env <- mkEnv
  defaultMain . testProperty "FirstApp" . propFirstApp $ env

dbPath :: FilePath
dbPath = "state-machine-tests.sqlite"

rmOkMissing :: FilePath -> IO ()
rmOkMissing fp =
  let
    logMissing = putStrLn $ fp <> " does not exist - nothing to do"
    checkRmException =
      liftA3 bool throw (const logMissing) isDoesNotExistError
  in
    removeFile fp `catch` checkRmException

portNum :: Word16
portNum = 3000

data Comment =
  Comment { topic   :: Text
          , comment :: Text
          } deriving (Eq, Show)

newtype CommentState (v :: * -> *) =
  CommentState (M.IntMap Comment)
  deriving (Eq, Show)

mkEnv :: IO Env
mkEnv =
  let
    c = Conf (Port 3000) (DBFilePath dbPath)
    edb = initDB (dbFilePath c)
    logErr = liftIO . hPutStrLn stderr
    splode = error . ("Error connecting to DB: " <>) . show
  in
    -- Ensure we get a clean DB whenever we get a new `Env`
    fmap (either splode (Env logErr c)) edb

initialState :: CommentState v
initialState = CommentState M.empty

-----------------------------------------------------
-- LIST
-----------------------------------------------------
data ListTopics (v :: * -> *) =
  ListTopics
  deriving (Eq, Show)

instance HTraversable ListTopics where
  htraverse _ ListTopics = pure ListTopics

cListTopics :: Command Gen (PropertyT WaiSession) CommentState
cListTopics =
  let
    gen :: CommentState v -> Maybe (Gen (ListTopics v))
    gen = const . Just . pure $ ListTopics

    execute ListTopics = do
      rsp <- lift . get $ "/list"
      pure $ WT.simpleBody rsp

    callbacks =
      [ Require (\(CommentState s) _i -> M.null s)
      , Ensure (\(CommentState b) (CommentState a) _i o ->
                  let
                    expected = Just . Set.fromList . fmap topic . M.elems $ a
                    actual = fmap Set.fromList . decode $ o
                  in
                    actual === expected
               )
      ]
  in
    Command gen execute callbacks

-----------------------------------------------------
-- ADD
-----------------------------------------------------
data AddComment (v :: * -> *) =
  AddComment BS.ByteString BS.ByteString
  deriving (Eq, Show)

instance HTraversable AddComment where
  htraverse _ (AddComment t c) = pure (AddComment t c)

cAddComment :: Command Gen (PropertyT WaiSession) CommentState
cAddComment =
  let
    gen _ = Just $ AddComment <$> utf8Gen <*> utf8Gen

    exe (AddComment t c) = do
      liftIO . print $ "Adding topic '" <> show t <> "', comment: '" <> show c <> "'"
      lift $ post ("/" <> t <> "/add") (LBS.fromStrict c)

    callbacks =
      [ Update $ \(CommentState s) (AddComment t c) _ ->
          let
            -- This won't work in parallel - would need STM or update
            -- API to return the ID of the added item
            newId =
              case M.maxViewWithKey s of
                Just ((k,_), _) -> k + 1
                Nothing         -> 0
            newComment = Comment (decodeUtf8 t) (decodeUtf8 c)
          in
            CommentState (M.insert newId newComment s)
      , Ensure $ \(CommentState old) (CommentState new) (AddComment t c) output -> do
          (snd . fst <$> M.maxViewWithKey new) === Just (Comment (decodeUtf8 t) (decodeUtf8 c))
          length old + 1 === length new
          WT.simpleBody output  === "Success"
          (statusCode . WT.simpleStatus $ output) === 200
      ]
  in
    Command gen exe callbacks

utf8Gen :: Gen BS.ByteString
utf8Gen = Gen.utf8 (Range.linear 1 100) Gen.alphaNum

propFirstApp :: Env -> Property
propFirstApp env =
  property $ do
    commands <- forAll $
      Gen.sequential (Range.linear 1 100) initialState [cListTopics, cAddComment]
    let session :: PropertyT WaiSession ()
        session =  executeSequential initialState commands
    hoist (`runWaiSession` app env) session
