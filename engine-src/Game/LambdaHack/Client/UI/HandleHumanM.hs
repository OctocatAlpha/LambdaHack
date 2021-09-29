-- | Semantics of human player commands.
module Game.LambdaHack.Client.UI.HandleHumanM
  ( cmdSemInCxtOfKM, updateKeyLast
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , noRemoteHumanCmd, cmdSemantics, cmdSemanticsLeader
  , addNoError, addLeader, weaveLeader
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import           Game.LambdaHack.Client.MonadClient
import           Game.LambdaHack.Client.Request
import           Game.LambdaHack.Client.State
import           Game.LambdaHack.Client.UI.HandleHelperM
import           Game.LambdaHack.Client.UI.HandleHumanGlobalM
import           Game.LambdaHack.Client.UI.HandleHumanLocalM
import           Game.LambdaHack.Client.UI.HumanCmd
import qualified Game.LambdaHack.Client.UI.Key as K
import           Game.LambdaHack.Client.UI.MonadClientUI
import           Game.LambdaHack.Client.UI.SessionUI
import           Game.LambdaHack.Common.Types

-- | Commands that are forbidden on a remote level, because they
-- would usually take time when invoked on one, but not necessarily do
-- what the player expects. Note that some commands that normally take time
-- are not included, because they don't take time in aiming mode
-- or their individual sanity conditions include a remote level check.
noRemoteHumanCmd :: HumanCmd -> Bool
noRemoteHumanCmd cmd = case cmd of
  Wait          -> True
  Wait10        -> True
  MoveItem{}    -> True
  Apply{}       -> True
  AlterDir{}    -> True
  AlterWithPointer{} -> True
  MoveOnceToXhair -> True
  RunOnceToXhair -> True
  ContinueToXhair -> True
  _ -> False

updateKeyLast :: K.KM -> HumanCmd -> KeyMacroFrame -> KeyMacroFrame
updateKeyLast km cmd macroFrame = case cmd of
  RepeatLast{} -> macroFrame
  Record{} -> macroFrame
  _ -> macroFrame {keyLast = Just km}

-- | The semantics of human player commands in terms of the client monad,
-- in context of the given @km@ as the last action.
--
-- Some time cosuming commands are enabled even in aiming mode, but cannot be
-- invoked in aiming mode on a remote level (level different than
-- the level of the leader). Commands that require a pointman fail
-- when no leader is designated.
cmdSemInCxtOfKM :: (MonadClient m, MonadClientUI m)
                => K.KM -> HumanCmd -> m (Either MError ReqUI)
cmdSemInCxtOfKM km cmd = do
  modifySession $ \sess ->
    sess {smacroFrame = updateKeyLast km cmd $ smacroFrame sess}
  cmdSemantics cmd

data CmdLeaderNeed m =
    CmdNoNeed (m (Either MError ReqUI))
  | CmdNeed (ActorId -> m (Either MError ReqUI))

cmdSemantics :: (MonadClient m, MonadClientUI m)
             => HumanCmd -> m (Either MError ReqUI)
cmdSemantics cmd = case cmdSemanticsLeader cmd of
  CmdNoNeed mreq -> mreq
  CmdNeed f -> do
    mleader <- getsClient sleader
    case mleader of
      Nothing -> weaveJust <$> failWith
        "command disabled when no pointman designated, choose another command"
      Just leader -> do
        if noRemoteHumanCmd cmd then do
          -- If in aiming mode, check if the current level is the same
          -- as player level and refuse performing the action otherwise.
          arena <- getArenaUI
          lidV <- viewedLevelUI
          if arena /= lidV then
            weaveJust <$> failWith
              "command disabled on a remote level, press ESC to switch back"
          else f leader
        else f leader

cmdSemanticsLeader :: (MonadClient m, MonadClientUI m)
                   => HumanCmd -> CmdLeaderNeed m
cmdSemanticsLeader cmd = case cmd of
  Macro kms -> addNoError $ macroHuman kms
  ByArea l -> CmdNoNeed $ byAreaHuman cmdSemInCxtOfKM l
  ByAimMode AimModeCmd{..} ->
    CmdNoNeed $ byAimModeHuman (cmdSemantics exploration) (cmdSemantics aiming)
  ComposeIfLocal cmd1 cmd2 ->
    CmdNoNeed $ composeIfLocalHuman (cmdSemantics cmd1) (cmdSemantics cmd2)
  ComposeUnlessError cmd1 cmd2 ->
    CmdNoNeed $ composeUnlessErrorHuman (cmdSemantics cmd1) (cmdSemantics cmd2)
  Compose2ndLocal cmd1 cmd2 ->
    CmdNoNeed $ compose2ndLocalHuman (cmdSemantics cmd1) (cmdSemantics cmd2)
  LoopOnNothing cmd1 -> CmdNoNeed $ loopOnNothingHuman (cmdSemantics cmd1)
  ExecuteIfClear cmd1 -> CmdNoNeed $ executeIfClearHuman (cmdSemantics cmd1)

  Wait -> weaveLeader $ \leader -> (ReqUITimed <$$> waitHuman leader)
  Wait10 -> weaveLeader $ \leader -> (ReqUITimed <$$> waitHuman10 leader)
  Yell -> weaveLeader $ \leader -> (ReqUITimed <$$> yellHuman leader)
  MoveDir v -> weaveLeader $ \leader ->
                 (ReqUITimed <$$> moveRunHuman leader True True False False v)
  RunDir v -> weaveLeader $ \leader ->
                (ReqUITimed <$$> moveRunHuman leader True True True True v)
  RunOnceAhead -> CmdNeed $ \leader -> ReqUITimed <$$> runOnceAheadHuman leader
  MoveOnceToXhair -> weaveLeader $ \leader ->
                       (ReqUITimed <$$> moveOnceToXhairHuman leader)
  RunOnceToXhair  -> weaveLeader $ \leader ->
                       (ReqUITimed <$$> runOnceToXhairHuman leader)
  ContinueToXhair -> weaveLeader $ \leader ->
                       (ReqUITimed <$$> continueToXhairHuman leader)
  MoveItem stores toCStore mverb auto ->
    weaveLeader $ \leader ->
      (ReqUITimed <$$> moveItemHuman leader stores toCStore mverb auto)
  Project -> weaveLeader $ \leader -> (ReqUITimed <$$> projectHuman leader)
  Apply -> weaveLeader $ \leader -> (ReqUITimed <$$> applyHuman leader)
  AlterDir -> weaveLeader $ \leader -> (ReqUITimed <$$> alterDirHuman leader)
  AlterWithPointer ->
    weaveLeader $ \leader -> (ReqUITimed <$$> alterWithPointerHuman leader)
  CloseDir -> weaveLeader $ \leader -> (ReqUITimed <$$> closeDirHuman leader)
  Help -> CmdNoNeed $ helpHuman cmdSemInCxtOfKM
  Hint -> CmdNoNeed $ hintHuman cmdSemInCxtOfKM
  ItemMenu -> CmdNeed $ \leader -> itemMenuHuman leader cmdSemInCxtOfKM
  ChooseItemMenu dialogMode ->
    CmdNeed $ \leader -> chooseItemMenuHuman leader cmdSemInCxtOfKM dialogMode
  MainMenu -> CmdNoNeed $ mainMenuHuman cmdSemInCxtOfKM
  MainMenuAutoOn -> CmdNoNeed $ mainMenuAutoOnHuman cmdSemInCxtOfKM
  MainMenuAutoOff -> CmdNoNeed $ mainMenuAutoOffHuman cmdSemInCxtOfKM
  Dashboard -> CmdNoNeed $ dashboardHuman cmdSemInCxtOfKM
  GameTutorialToggle ->
    CmdNoNeed $ gameTutorialToggle >> challengeMenuHuman cmdSemInCxtOfKM
  GameDifficultyIncr ->
    CmdNoNeed $ gameDifficultyIncr >> challengeMenuHuman cmdSemInCxtOfKM
  GameFishToggle ->
    CmdNoNeed $ gameFishToggle >> challengeMenuHuman cmdSemInCxtOfKM
  GameGoodsToggle ->
    CmdNoNeed $ gameGoodsToggle >> challengeMenuHuman cmdSemInCxtOfKM
  GameWolfToggle ->
    CmdNoNeed $ gameWolfToggle >> challengeMenuHuman cmdSemInCxtOfKM
  GameKeeperToggle ->
    CmdNoNeed $ gameKeeperToggle >> challengeMenuHuman cmdSemInCxtOfKM
  GameScenarioIncr ->
    CmdNoNeed $ gameScenarioIncr >> challengeMenuHuman cmdSemInCxtOfKM

  GameRestart -> CmdNoNeed $ weaveJust <$> gameRestartHuman
  GameQuit -> CmdNoNeed $ weaveJust <$> gameQuitHuman
  GameDrop -> CmdNoNeed $ weaveJust <$> fmap Right gameDropHuman
  GameExit -> CmdNoNeed $ weaveJust <$> fmap Right gameExitHuman
  GameSave -> CmdNoNeed $ weaveJust <$> fmap Right gameSaveHuman
  Doctrine -> CmdNoNeed $ weaveJust <$> doctrineHuman
  Automate -> CmdNoNeed $ weaveJust <$> automateHuman
  AutomateToggle -> CmdNoNeed $ weaveJust <$> automateToggleHuman
  AutomateBack -> CmdNoNeed $ automateBackHuman

  ChooseItem dialogMode ->
    CmdNeed $ \leader -> Left <$> chooseItemHuman leader dialogMode
  ChooseItemProject ts ->
    CmdNeed $ \leader -> Left <$> chooseItemProjectHuman leader ts
  ChooseItemApply ts ->
    CmdNeed $ \leader -> Left <$> chooseItemApplyHuman leader ts
  PickLeader k -> CmdNoNeed $ Left <$> pickLeaderHuman k
  PickLeaderWithPointer ->
    CmdNeed $ \leader -> Left <$> pickLeaderWithPointerHuman leader
  PointmanCycle direction ->
    CmdNeed $ \leader -> Left <$> pointmanCycleHuman leader direction
  PointmanCycleLevel direction ->
    CmdNeed $ \leader -> Left <$> pointmanCycleLevelHuman leader direction
  SelectActor -> addLeader selectActorHuman
  SelectNone -> addNoError selectNoneHuman
  SelectWithPointer -> CmdNoNeed $ Left <$> selectWithPointerHuman
  Repeat n -> addNoError $ repeatHuman n
  RepeatLast n -> addNoError $ repeatLastHuman n
  Record -> addNoError recordHuman
  AllHistory -> addNoError allHistoryHuman
  LastHistory -> addNoError lastHistoryHuman
  MarkVision ->
    CmdNoNeed $ markVisionHuman >> settingsMenuHuman cmdSemInCxtOfKM
  MarkSmell ->
    CmdNoNeed $ markSmellHuman >> settingsMenuHuman cmdSemInCxtOfKM
  MarkSuspect ->
    CmdNoNeed $ markSuspectHuman >> settingsMenuHuman cmdSemInCxtOfKM
  MarkAnim ->
    CmdNoNeed $ markAnimHuman >> settingsMenuHuman cmdSemInCxtOfKM
  OverrideTut ->
    CmdNoNeed $ overrideTutHuman >> settingsMenuHuman cmdSemInCxtOfKM
  SettingsMenu -> CmdNoNeed $ settingsMenuHuman cmdSemInCxtOfKM
  ChallengeMenu -> CmdNoNeed $ challengeMenuHuman cmdSemInCxtOfKM
  PrintScreen -> addNoError printScreenHuman

  Cancel -> addNoError cancelHuman
  Accept -> addLeader acceptHuman
  DetailCycle -> addLeader detailCycleHuman
  ClearTargetIfItemClear -> addLeader $ clearTargetIfItemClearHuman
  ItemClear -> addNoError itemClearHuman
  MoveXhair v k -> CmdNeed $ \leader -> Left <$> moveXhairHuman leader v k
  AimTgt -> addLeader $ aimTgtHuman
  AimFloor -> addLeader aimFloorHuman
  AimEnemy -> addLeader aimEnemyHuman
  AimItem -> addLeader aimItemHuman
  AimAscend k -> CmdNeed $ \leader -> Left <$> aimAscendHuman leader k
  EpsIncr b -> addNoError $ epsIncrHuman b
  XhairUnknown -> CmdNeed $ \leader -> Left <$> xhairUnknownHuman leader
  XhairItem -> CmdNeed $ \leader -> Left <$> xhairItemHuman leader
  XhairStair up -> CmdNeed $ \leader -> Left <$> xhairStairHuman leader up
  XhairPointerFloor -> addLeader xhairPointerFloorHuman
  XhairPointerMute -> addLeader xhairPointerMuteHuman
  XhairPointerEnemy -> addLeader xhairPointerEnemyHuman
  AimPointerFloor -> addLeader aimPointerFloorHuman
  AimPointerEnemy -> addLeader aimPointerEnemyHuman

addNoError :: Monad m => m () -> CmdLeaderNeed m
addNoError cmdCli = CmdNoNeed $ cmdCli >> return (Left Nothing)

addLeader :: Monad m => (ActorId -> m ()) -> CmdLeaderNeed m
addLeader cmdCli =
  CmdNeed $ \leader -> cmdCli leader >> return (Left Nothing)

weaveLeader :: Monad m => (ActorId -> m (FailOrCmd ReqUI)) -> CmdLeaderNeed m
weaveLeader cmdCli =
  CmdNeed $ \leader -> weaveJust <$> cmdCli leader
