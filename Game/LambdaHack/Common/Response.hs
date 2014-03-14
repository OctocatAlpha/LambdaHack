-- | Abstract syntax of client commands.
-- See
-- <https://github.com/kosmikus/LambdaHack/wiki/Client-server-architecture>.
module Game.LambdaHack.Common.Response
  ( ResponseAI(..), ResponseUI(..)
  , debugResponseAI, debugResponseUI, debugAid
  ) where

import Control.Concurrent.STM.TQueue
import qualified Data.EnumMap.Strict as EM
import Data.Text (Text)
import qualified Data.Text as T

import Game.LambdaHack.Atomic
import Game.LambdaHack.Common.Action
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Request
import Game.LambdaHack.Common.State
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Frontend

-- | Abstract syntax of client commands that don't use the UI.
data ResponseAI =
    RespUpdAtomicAI !UpdAtomic
  | RespQueryAI !ActorId
  | RespPingAI
  deriving Show

-- | Abstract syntax of client commands that use the UI.
data ResponseUI =
    RespUpdAtomicUI !UpdAtomic
  | RespSfxAtomicUI !SfxAtomic
  | RespQueryUI !ActorId
  | RespPingUI
  deriving Show

-- These can't use MonadClient and print more information,
-- because they are used by the server, because we want a single log
-- knowing the order server received requests and sent responses
-- and clients interleave and block non-deterministically so their logs
-- would not be so valuable.
debugResponseAI :: MonadReadState m => ResponseAI -> m Text
debugResponseAI cmd = case cmd of
  RespUpdAtomicAI cmdA@UpdPerception{} -> debugPlain cmd cmdA
  RespUpdAtomicAI cmdA@UpdResume{} -> debugPlain cmd cmdA
  RespUpdAtomicAI cmdA@UpdSpotTile{} -> debugPlain cmd cmdA
  RespUpdAtomicAI cmdA -> debugPretty cmd cmdA
  RespQueryAI aid -> debugAid aid "RespQueryAI" cmd
  RespPingAI -> return $! tshow cmd

debugResponseUI :: MonadReadState m => ResponseUI -> m Text
debugResponseUI cmd = case cmd of
  RespUpdAtomicUI cmdA@UpdPerception{} -> debugPlain cmd cmdA
  RespUpdAtomicUI cmdA@UpdResume{} -> debugPlain cmd cmdA
  RespUpdAtomicUI cmdA@UpdSpotTile{} -> debugPlain cmd cmdA
  RespUpdAtomicUI cmdA -> debugPretty cmd cmdA
  RespSfxAtomicUI sfx -> do
    ps <- posSfxAtomic sfx
    return $! tshow (cmd, ps)
  RespQueryUI aid -> debugAid aid "RespQueryUI" cmd
  RespPingUI -> return $! tshow cmd

debugPretty :: (MonadReadState m, Show a) => a -> UpdAtomic -> m Text
debugPretty cmd cmdA = do
  ps <- posUpdAtomic cmdA
  return $! tshow (cmd, ps)

debugPlain :: (MonadReadState m, Show a) => a -> UpdAtomic -> m Text
debugPlain cmd cmdA = do
  ps <- posUpdAtomic cmdA
  return $! T.pack $ show (cmd, ps)  -- too large for pretty show

data DebugAid a = DebugAid
  { label   :: !Text
  , cmd     :: !a
  , lid     :: !LevelId
  , time    :: !Time
  , aid     :: !ActorId
  , faction :: !FactionId
  }
  deriving Show

debugAid :: (MonadReadState m, Show a) => ActorId -> Text -> a -> m Text
debugAid aid label cmd =
  if aid == toEnum (-1) then
    return $ "Pong:" <+> tshow label <+> tshow cmd
  else do
    b <- getsState $ getActorBody aid
    time <- getsState $ getLocalTime (blid b)
    return $! tshow DebugAid { label
                             , cmd
                             , lid = blid b
                             , time
                             , aid
                             , faction = bfid b }
