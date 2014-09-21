-- | Display atomic commands received by the client.
module Game.LambdaHack.Client.UI.DisplayAtomicClient
  ( displayRespUpdAtomicUI, displayRespSfxAtomicUI
  ) where

import Control.Exception.Assert.Sugar
import Control.Monad
import qualified Data.EnumMap.Strict as EM
import qualified Data.IntMap.Strict as IM
import Data.Maybe
import Data.Monoid
import Data.Tuple
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Atomic
import Game.LambdaHack.Client.CommonClient
import Game.LambdaHack.Client.ItemSlot
import Game.LambdaHack.Client.MonadClient
import Game.LambdaHack.Client.State
import Game.LambdaHack.Client.UI.Animation
import Game.LambdaHack.Client.UI.MonadClientUI
import Game.LambdaHack.Client.UI.MsgClient
import Game.LambdaHack.Client.UI.WidgetClient
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import qualified Game.LambdaHack.Common.Color as Color
import qualified Game.LambdaHack.Common.Dice as Dice
import qualified Game.LambdaHack.Common.Effect as Effect
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Item
import Game.LambdaHack.Common.ItemDescription
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.State
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Content.ItemKind
import Game.LambdaHack.Content.ModeKind
import Game.LambdaHack.Content.TileKind

-- * RespUpdAtomicUI

-- TODO: let user configure which messages are not created, which are
-- slightly hidden, which are shown and which flash and center screen
-- and perhaps highligh the related location/actor. Perhaps even
-- switch to the actor, changing HP displayed on screen, etc.
-- but it's too short a clip to read the numbers, so probably
-- highlighing should be enough.
-- TODO: for a start, flesh out the verbose variant and then add
-- a single client debug option that flips verbosity
--
-- | Visualize atomic actions sent to the client. This is done
-- in the global state after the command is executed and after
-- the client state is modified by the command.
displayRespUpdAtomicUI :: MonadClientUI m
                       => Bool -> State -> StateClient -> UpdAtomic -> m ()
displayRespUpdAtomicUI verbose _oldState oldStateClient cmd = case cmd of
  -- Create/destroy actors and items.
  UpdCreateActor aid body _ -> createActorUI aid body verbose "appear"
  UpdDestroyActor aid body _ -> do
    destroyActorUI aid body "die" "be destroyed" verbose
    side <- getsClient sside
    when (bfid body == side && not (bproj body)) stopPlayBack
  UpdCreateItem iid _ kit c -> do
    -- TODO: probably not Nothing if container not CGround
    updateItemSlot Nothing iid
    itemVerbMU iid kit (MU.Text $ "appear" <+> ppContainer c) (storeFromC c)
    stopPlayBack
  UpdDestroyItem iid _ kit c -> itemVerbMU iid kit "disappear" (storeFromC c)
  UpdSpotActor aid body _ -> createActorUI aid body verbose "be spotted"
  UpdLoseActor aid body _ ->
    destroyActorUI aid body "be missing in action" "be lost" verbose
  UpdSpotItem iid _ kit c -> do
    -- We assign slots to all items visible on the floor,
    -- but some of the slots are later on recycled and then
    -- we report spotting the items again.
    (letterSlots, numberSlots) <- getsClient sslots
    case ( lookup iid $ map swap $ EM.assocs letterSlots
         , lookup iid $ map swap $ IM.assocs numberSlots ) of
      (Nothing, Nothing) -> do
        updateItemSlot Nothing iid
        case c of
          CActor{} -> return ()  -- not actionable at this time
          CFloor lid p -> do
            scursorOld <- getsClient scursor
            case scursorOld of
              TEnemy{} -> return ()  -- probably too important to overwrite
              TEnemyPos{} -> return ()
              _ -> modifyClient $ \cli -> cli {scursor = TPoint lid p}
            itemVerbMU iid kit "be spotted" CGround
            stopPlayBack
          CTrunk{} -> return ()
      _ -> return ()  -- seen recently (still has a slot assigned)
  UpdLoseItem{} -> skip
  -- Move actors and items.
  UpdMoveActor aid _ _ -> lookAtMove aid
  UpdWaitActor aid _ -> when verbose $ aVerbMU aid "wait"
  UpdDisplaceActor source target -> displaceActorUI source target
  UpdMoveItem iid k aid c1 c2 -> moveItemUI verbose iid k aid c1 c2
  -- Change actor attributes.
  UpdAgeActor{} -> skip
  UpdRefillHP aid n -> do
    when verbose $
      aVerbMU aid $ MU.Text $ (if n > 0 then "heal" else "lose")
                              <+> tshow (abs n) <> "HP"
    mleader <- getsClient _sleader
    when (Just aid == mleader) $ do
      b <- getsState $ getActorBody aid
      hpMax <- sumOrganEqpClient Effect.EqpSlotAddMaxHP aid
      when (bhp b == xM hpMax && hpMax > 0) $ do
        actorVerbMU aid b "recover your health fully"
        stopPlayBack
  UpdRefillCalm aid calmDelta ->
    when (calmDelta == minusM) $ do  -- lower deltas come from hits; obvious
      side <- getsClient sside
      b <- getsState $ getActorBody aid
      when (bfid b == side) $ do
        fact <- getsState $ (EM.! bfid b) . sfactionD
        allFoes  <- getsState $ actorRegularList (isAtWar fact) (blid b)
        let closeFoes = filter ((<= 3) . chessDist (bpos b) . bpos) allFoes
        when (null closeFoes) $ do  -- obvious where the feeling comes from
          aVerbMU aid "hear something"
          msgDuplicateScrap
  UpdOldFidActor{} -> skip
  UpdTrajectory{} -> skip
  UpdColorActor{} -> skip
  -- Change faction attributes.
  UpdQuitFaction fid mbody _ toSt -> quitFactionUI fid mbody toSt
  UpdLeadFaction fid (Just (source, _)) (Just (target, _)) -> do
    side <- getsClient sside
    when (fid == side) $ do
      fact <- getsState $ (EM.! side) . sfactionD
      -- This faction can't run with multiple actors, so this is not
      -- a leader change while running, but rather server changing
      -- their leader, which the player should be alerted to.
      when (noRunWithMulti fact) stopPlayBack
      actorD <- getsState sactorD
      case EM.lookup source actorD of
        Just sb | bhp sb <= 0 -> assert (not $ bproj sb) $ do
          -- Regardless who the leader is, give proper names here, not 'you'.
          tb <- getsState $ getActorBody target
          let subject = partActor tb
              object  = partActor sb
          msgAdd $ makeSentence [ MU.SubjectVerbSg subject "take command"
                                , "from", object ]
        _ ->
          return ()
          -- TODO: report when server changes spawner's leader;
          -- perhaps don't switch _sleader in HandleAtomicClient,
          -- compare here and switch here? too hacky? fails for AI?
  UpdLeadFaction{} -> skip
  UpdDiplFaction fid1 fid2 _ toDipl -> do
    name1 <- getsState $ gname . (EM.! fid1) . sfactionD
    name2 <- getsState $ gname . (EM.! fid2) . sfactionD
    let showDipl Unknown = "unknown to each other"
        showDipl Neutral = "in neutral diplomatic relations"
        showDipl Alliance = "allied"
        showDipl War = "at war"
    msgAdd $ name1 <+> "and" <+> name2 <+> "are now" <+> showDipl toDipl <> "."
  UpdTacticFaction{} -> skip
  UpdAutoFaction fid b -> do
    side <- getsClient sside
    when (fid == side) $ setFrontAutoYes b
  UpdRecordKill{} -> skip
  -- Alter map.
  UpdAlterTile{} -> when verbose $ return ()  -- TODO: door opens
  UpdAlterClear _ k -> msgAdd $ if k > 0
                                then "You hear grinding noises."
                                else "You hear fizzing noises."
  UpdSearchTile aid p fromTile toTile -> do
    Kind.COps{cotile = Kind.Ops{okind}} <- getsState scops
    b <- getsState $ getActorBody aid
    lvl <- getLevel $ blid b
    subject <- partAidLeader aid
    let t = lvl `at` p
        verb | t == toTile = "confirm"
             | otherwise = "reveal"
        subject2 = MU.Text $ tname $ okind fromTile
        verb2 = "be"
    let msg = makeSentence [ MU.SubjectVerbSg subject verb
                           , "that the"
                           , MU.SubjectVerbSg subject2 verb2
                           , "a hidden"
                           , MU.Text $ tname $ okind toTile ]
    msgAdd msg
  UpdLearnSecrets{} -> skip
  UpdSpotTile{} -> skip
  UpdLoseTile{} -> skip
  UpdAlterSmell{} -> skip
  UpdSpotSmell{} -> skip
  UpdLoseSmell{} -> skip
  -- Assorted.
  UpdAgeGame {} -> skip
  UpdDiscover _ _ iid _ _ -> discover oldStateClient iid
  UpdCover{} ->  skip  -- don't spam when doing undo
  UpdDiscoverKind _ _ iid _ -> discover oldStateClient iid
  UpdCoverKind{} ->  skip  -- don't spam when doing undo
  UpdDiscoverSeed _ _ iid _ -> discover oldStateClient iid
  UpdCoverSeed{} -> skip  -- don't spam when doing undo
  UpdPerception{} -> skip
  UpdRestart fid _ _ _ _ _ -> do
    mode <- getModeClient
    msgAdd $ "New game started in" <+> mname mode <+> "mode." <+> mdesc mode
    -- TODO: use a vertical animation instead, e.g., roll down,
    -- and reveal the first frame of a new game, not blank screen.
    history <- getsClient shistory
    when (lengthHistory history > 1) $ fadeOutOrIn False
    fact <- getsState $ (EM.! fid) . sfactionD
    setFrontAutoYes $ isAIFact fact
  UpdRestartServer{} -> skip
  UpdResume fid _ -> do
    fact <- getsState $ (EM.! fid) . sfactionD
    setFrontAutoYes $ isAIFact fact
  UpdResumeServer{} -> skip
  UpdKillExit{} -> skip
  UpdWriteSave -> when verbose $ msgAdd "Saving backup."
  UpdMsgAll msg -> msgAdd msg
  UpdRecordHistory _ -> recordHistory

lookAtMove :: MonadClientUI m => ActorId -> m ()
lookAtMove aid = do
  body <- getsState $ getActorBody aid
  side <- getsClient sside
  tgtMode <- getsClient stgtMode
  when (not (bproj body)
        && bfid body == side
        && isNothing tgtMode) $ do  -- targeting does a more extensive look
    lookMsg <- lookAt False "" True (bpos body) aid ""
    msgAdd lookMsg
  fact <- getsState $ (EM.! bfid body) . sfactionD
  if side == bfid body then do
    foes <- getsState $ actorList (isAtWar fact) (blid body)
    when (any (adjacent (bpos body) . bpos) foes) stopPlayBack
  else when (isAtWar fact side) $ do
    friends <- getsState $ actorRegularList (== side) (blid body)
    when (any (adjacent (bpos body) . bpos) friends) stopPlayBack

-- | Sentences such as \"Dog barks loudly.\".
actorVerbMU :: MonadClientUI m => ActorId -> Actor -> MU.Part -> m ()
actorVerbMU aid b verb = do
  subject <- partActorLeader aid b
  msgAdd $ makeSentence [MU.SubjectVerbSg subject verb]

aVerbMU :: MonadClientUI m => ActorId -> MU.Part -> m ()
aVerbMU aid verb = do
  b <- getsState $ getActorBody aid
  actorVerbMU aid b verb

itemVerbMU :: MonadClientUI m
           => ItemId -> ItemQuant -> MU.Part -> CStore -> m ()
itemVerbMU iid kit@(k, _) verb cstore = assert (k > 0) $ do
  itemToF <- itemToFullClient
  let subject = partItemWs kit cstore (itemToF iid kit)
      msg | k > 1 = makeSentence [MU.SubjectVerb MU.PlEtc MU.Yes subject verb]
          | otherwise = makeSentence [MU.SubjectVerbSg subject verb]
  msgAdd msg

aiVerbMU :: MonadClientUI m
         => ActorId -> MU.Part -> ItemId -> ItemQuant -> CStore -> m ()
aiVerbMU aid verb iid kit cstore = do
  itemToF <- itemToFullClient
  subject <- partAidLeader aid
  let msg = makeSentence [ MU.SubjectVerbSg subject verb
                         , partItemWs kit cstore (itemToF iid kit) ]
  msgAdd msg

msgDuplicateScrap :: MonadClientUI m => m ()
msgDuplicateScrap = do
  report <- getsClient sreport
  history <- getsClient shistory
  let (lastMsg, repRest) = lastMsgOfReport report
      lastDup = isJust . findInReport (== lastMsg)
      lastDuplicated = lastDup repRest
                       || maybe False lastDup (lastReportOfHistory history)
  when lastDuplicated $
    modifyClient $ \cli -> cli {sreport = repRest}

-- TODO: "XXX spots YYY"? or blink or show the changed cursor?
createActorUI :: MonadClientUI m => ActorId -> Actor -> Bool -> MU.Part -> m ()
createActorUI aid body verbose verb = do
  side <- getsClient sside
  when (bfid body /= side && not (bproj body) || verbose) $
    actorVerbMU aid body verb
  when (bfid body /= side) $ do
    fact <- getsState $ (EM.! bfid body) . sfactionD
    when (not (bproj body) && isAtWar fact side) $ do
      -- Target even if nobody can aim at the enemy. Let's home in on him
      -- and then we can aim or melee. We set permit to False, because it's
      -- technically very hard to check aimability here, because we are
      -- in-between turns and, e.g., leader's move has not yet been taken
      -- into account.
      modifyClient $ \cli -> cli {scursor = TEnemy aid False}
    stopPlayBack
  when (bfid body == side && not (bproj body)) $ lookAtMove aid

destroyActorUI :: MonadClientUI m
               => ActorId -> Actor -> MU.Part -> MU.Part -> Bool -> m ()
destroyActorUI aid body verb verboseVerb verbose = do
  side <- getsClient sside
  if (bfid body == side && bhp body <= 0 && not (bproj body)) then do
    actorVerbMU aid body verb
    void $ displayMore ColorBW ""
  else when verbose $ actorVerbMU aid body verboseVerb

moveItemUI :: MonadClientUI m
           => Bool -> ItemId -> Int -> ActorId -> CStore -> CStore
           -> m ()
moveItemUI verbose iid k aid c1 c2 = do
  side <- getsClient sside
  b <- getsState $ getActorBody aid
  case (c1, c2) of
    (_, _) | c1 == CGround -> do
      when (bfid b == side) $ updateItemSlot (Just aid) iid
      fact <- getsState $ (EM.! bfid b) . sfactionD
      let underAI = isAIFact fact
      mleader <- getsClient _sleader
      if Just aid == mleader && not underAI then do
        itemToF <- itemToFullClient
        (letterSlots, _) <- getsClient sslots
        bag <- getsState $ getCBag $ CActor aid c2
        let n = bag EM.! iid
        case lookup iid $ map swap $ EM.assocs letterSlots of
          Just l -> msgAdd $ makePhrase
                      [ "\n"
                      , slotLabel $ Left l
                      , "-"
                      , partItemWs n c2 (itemToF iid n)
                      , "\n" ]
          Nothing -> return ()
      else when (c1 == CGround && c1 /= c2) $
        aiVerbMU aid "get" iid (k, []) c2
    (_, CGround) | c1 /= c2 -> do
      when verbose $ aiVerbMU aid "drop" iid (k, []) c1
      if bfid b == side
        then updateItemSlot (Just aid) iid
        else updateItemSlot Nothing iid
    _ -> return ()

displaceActorUI :: MonadClientUI m => ActorId -> ActorId -> m ()
displaceActorUI source target = do
  sb <- getsState $ getActorBody source
  tb <- getsState $ getActorBody target
  spart <- partActorLeader source sb
  tpart <- partActorLeader target tb
  let msg = makeSentence [MU.SubjectVerbSg spart "displace", tpart]
  msgAdd msg
  when (bfid sb /= bfid tb) $ do
    lookAtMove source
    lookAtMove target
  let ps = (bpos tb, bpos sb)
  animFrs <- animate (blid sb) $ swapPlaces ps
  displayActorStart sb animFrs

quitFactionUI :: MonadClientUI m
              => FactionId -> Maybe Actor -> Maybe Status -> m ()
quitFactionUI fid mbody toSt = do
  Kind.COps{coitem=Kind.Ops{okind, ouniqGroup}} <- getsState scops
  fact <- getsState $ (EM.! fid) . sfactionD
  let fidName = MU.Text $ gname fact
      horror = isHorrorFact fact
  side <- getsClient sside
  let msgIfSide _ | fid /= side = Nothing
      msgIfSide s = Just s
      (startingPart, partingPart) = case toSt of
        _ | horror ->
          (Nothing, Nothing)  -- Ignore summoned actors' factions.
        Just Status{stOutcome=Killed} ->
          ( Just "be eliminated"
          , msgIfSide "Let's hope another party can save the day!" )
        Just Status{stOutcome=Defeated} ->
          ( Just "be decisively defeated"
          , msgIfSide "Let's hope your new overlords let you live." )
        Just Status{stOutcome=Camping} ->
          ( Just "order save and exit"
          , Just $ if fid == side
                   then "See you soon, stronger and braver!"
                   else "See you soon, stalwart warrior!" )
        Just Status{stOutcome=Conquer} ->
          ( Just "vanquish all foes"
          , msgIfSide "Can it be done in a better style, though?" )
        Just Status{stOutcome=Escape} ->
          ( Just "achieve victory"
          , msgIfSide "Can it be done better, though?" )
        Just Status{stOutcome=Restart, stNewGame=Just gn} ->
          ( Just $ MU.Text $ "order mission restart in" <+> tshow gn <+> "mode"
          , Just $ if fid == side
                   then "This time for real."
                   else "Somebody couldn't stand the heat." )
        Just Status{stOutcome=Restart, stNewGame=Nothing} ->
          assert `failure` (fid, mbody, toSt)
        Nothing ->
          (Nothing, Nothing)  -- Wipe out the quit flag for the savegame files.
  case startingPart of
    Nothing -> return ()
    Just sp -> do
      let msg = makeSentence [MU.SubjectVerbSg fidName sp]
      msgAdd msg
  case (toSt, partingPart) of
    (Just status, Just pp) -> do
      (bag, total) <- case mbody of
        Just body | fid == side -> getsState $ calculateTotal body
        _ -> case gleader fact of
          Nothing -> return (EM.empty, 0)
          Just (aid, _) -> do
            b <- getsState $ getActorBody aid
            getsState $ calculateTotal b
      let currencyName = MU.Text $ iname $ okind $ ouniqGroup "currency"
          itemMsg = makeSentence [ "Your loot is worth"
                                 , MU.CarWs total currencyName ]
                    <+> moreMsg
      startingSlide <- promptToSlideshow moreMsg
      recordHistory  -- we are going to exit or restart, so record
      itemSlides <-
        if EM.null bag then return mempty
        else do
          io <- itemOverlay CGround bag
          overlayToSlideshow itemMsg io
      -- Show score for any UI client (except after ESC),
      -- even though it is saved only for human UI clients.
      scoreSlides <- scoreToSlideshow total status
      partingSlide <- promptToSlideshow $ pp <+> moreMsg
      shutdownSlide <- promptToSlideshow pp
      escAI <- getsClient sescAI
      unless (escAI == EscAIExited) $
        -- TODO: First ESC cancels items display.
        void $ getInitConfirms ColorFull []
             $ startingSlide <> itemSlides
        -- TODO: Second ESC cancels high score and parting message display.
        -- The last slide stays onscreen during shutdown, etc.
               <> scoreSlides <> partingSlide <> shutdownSlide
      -- TODO: perhaps use a vertical animation instead, e.g., roll down
      -- and put it before item and score screens (on blank background)
      unless (fmap stOutcome toSt == Just Camping) $ fadeOutOrIn True
    _ -> return ()

discover :: MonadClientUI m => StateClient -> ItemId ->  m ()
discover oldcli iid = do
  cops <- getsState scops
  itemToF <- itemToFullClient
  let itemFull = itemToF iid (1, [])
      (knownName, knownAEText) = partItem CGround itemFull
      -- Wipe out the whole knowledge of the item to make sure the two names
      -- in the message differ even if, e.g., the item is described as
      -- "of many effects".
      itemSecret = itemNoDisco (itemBase itemFull, itemK itemFull)
      (secretName, secretAEText) = partItem CGround itemSecret
      msg = makeSentence
        [ "the", MU.SubjectVerbSg (MU.Phrase [secretName, secretAEText])
                                  "turn out to be"
        , MU.AW $ MU.Phrase [knownName, knownAEText] ]
      oldItemFull =
        itemToFull cops (sdiscoKind oldcli) (sdiscoEffect oldcli)
                   iid (itemBase itemFull) (1, [])
  -- Compare descriptions of all aspects and effects to determine
  -- if the discovery was meaningful to the player.
  when (textAllAE False CEqp itemFull /= textAllAE False CEqp oldItemFull) $
    msgAdd msg

-- * RespSfxAtomicUI

-- | Display special effects (text, animation) sent to the client.
displayRespSfxAtomicUI :: MonadClientUI m => Bool -> SfxAtomic -> m ()
displayRespSfxAtomicUI verbose sfx = case sfx of
  SfxStrike source target iid b -> strike source target iid b
  SfxRecoil source target _ _ -> do
    spart <- partAidLeader source
    tpart <- partAidLeader target
    msgAdd $ makeSentence [MU.SubjectVerbSg spart "shrink away from", tpart]
  SfxProject aid iid -> aiVerbMU aid "aim" iid (1, []) CInv
  SfxCatch aid iid -> aiVerbMU aid "catch" iid (1, []) CInv
  SfxActivate aid iid k -> aiVerbMU aid "activate" iid (k, []) CInv
  SfxCheck aid iid k -> aiVerbMU aid "deactivate" iid (k, []) CInv
  SfxTrigger aid _p _feat ->
    when verbose $ aVerbMU aid "trigger"  -- TODO: opens door, etc.
  SfxShun aid _p _ ->
    when verbose $ aVerbMU aid "shun"  -- TODO: shuns stairs down
  SfxEffect fidSource aid effect -> do
    b <- getsState $ getActorBody aid
    side <- getsClient sside
    let fid = bfid b
    if bhp b <= 0 && not (bproj b) || bhp b < 0 then do
      -- We assume the effect is the cause of incapacitation.
      let firstFall | fid == side && bproj b = "fall apart"
                    | fid == side = "fall down"
                    | bproj b = "break up"
                    | otherwise = "collapse"
          hurtExtra | fid == side && bproj b = "be reduced to dust"
                    | fid == side = "be stomped flat"
                    | bproj b = "be shattered into little pieces"
                    | otherwise = "be reduced to a bloody pulp"
      subject <- partActorLeader aid b
      let deadPreviousTurn p = p < 0
                               && (bhp b <= p && not (bproj b)
                                   || bhp b < p)
          (deadBefore, verbDie) =
            case effect of
              Effect.Hurt p | deadPreviousTurn (xM $ Dice.maxDice p) ->
                (True, hurtExtra)
              Effect.RefillHP p | deadPreviousTurn (xM p) -> (True, hurtExtra)
              _ -> (False, firstFall)
          msgDie = makeSentence [MU.SubjectVerbSg subject verbDie]
      msgAdd msgDie
      when (fid == side && not (bproj b)) $ do
        animDie <- if deadBefore
                   then animate (blid b)
                        $ twirlSplash (bpos b, bpos b) Color.Red Color.Red
                   else animate (blid b) $ deathBody $ bpos b
        displayActorStart b animDie
    else case effect of
        Effect.NoEffect t -> msgAdd $ "Nothing happens." <+> t
        Effect.RefillHP p | p == 1 -> skip  -- no spam from regen items
        Effect.RefillHP p | p > 0 -> do
          if fid == side then
            actorVerbMU aid b "feel healthier"
          else
            actorVerbMU aid b "look healthier"
          let ps = (bpos b, bpos b)
          animFrs <- animate (blid b) $ twirlSplash ps Color.BrBlue Color.Blue
          displayActorStart b animFrs
        Effect.RefillHP _ -> do
          if fid == side then
            actorVerbMU aid b "feel wounded"
          else
            actorVerbMU aid b "look wounded"
          let ps = (bpos b, bpos b)
          animFrs <- animate (blid b) $ twirlSplash ps Color.BrRed Color.Red
          displayActorStart b animFrs
        Effect.Hurt{} -> skip  -- avoid spam; SfxStrike just sent
        Effect.RefillCalm p | p == 1 -> skip  -- no spam from regen items
        Effect.RefillCalm p | p > 0 -> do
          if fid == side then
            actorVerbMU aid b "feel calmer"
          else
            actorVerbMU aid b "look calmer"
          let ps = (bpos b, bpos b)
          animFrs <- animate (blid b) $ twirlSplash ps Color.BrBlue Color.Blue
          displayActorStart b animFrs
        Effect.RefillCalm _ -> do
          if fid == side then
            actorVerbMU aid b "feel agitated"
          else
            actorVerbMU aid b "look agitated"
          let ps = (bpos b, bpos b)
          animFrs <- animate (blid b) $ twirlSplash ps Color.BrRed Color.Red
          displayActorStart b animFrs
        Effect.Dominate -> do
          -- For subsequent messages use the proper name, never "you".
          let subject = partActor b
          if fid /= fidSource then do  -- before domination
            if bcalm b == 0 then do -- sometimes only a coincidence, but nm
              aVerbMU aid $ MU.Text "yield, under extreme pressure"
            else if fid == side then
              aVerbMU aid $ MU.Text "black out, dominated by foes"
            else
              aVerbMU aid $ MU.Text "decide abrubtly to switch allegiance"
            fidName <- getsState $ gname . (EM.! fid) . sfactionD
            let verb = "be no longer controlled by"
            msgAdd $ makeSentence
              [MU.SubjectVerbSg subject verb, MU.Text fidName]
            when (fid == side) $ void $ displayMore ColorFull ""
          else do
            fidSourceName <- getsState $ gname . (EM.! fidSource) . sfactionD
            let verb = "be now under"
            msgAdd $ makeSentence
              [MU.SubjectVerbSg subject verb, MU.Text fidSourceName, "control"]
        Effect.Impress{} ->
          actorVerbMU aid b
          $ if boldfid b /= bfid b
            then
              "get sobered and refocused by the fragrant moisture"
            else
              "inhale the sweet smell that weakens resolve and erodes loyalty"
        Effect.CallFriend{} -> skip
        Effect.Summon{} -> skip
        Effect.CreateItem{} -> skip
        Effect.ApplyPerfume ->
          msgAdd "The fragrance quells all scents in the vicinity."
        Effect.Burn{} ->
          if fid == side then
            actorVerbMU aid b "feel burned"
          else
            actorVerbMU aid b "look burned"
        Effect.Ascend k | k > 0 -> actorVerbMU aid b "find a way upstairs"
        Effect.Ascend k | k < 0 -> actorVerbMU aid b "find a way downstairs"
        Effect.Ascend{} -> assert `failure` sfx
        Effect.Escape{} -> skip
        Effect.Paralyze{} -> actorVerbMU aid b "be paralyzed"
        Effect.InsertMove{} -> actorVerbMU aid b "move with extreme speed"
        Effect.DropBestWeapon -> actorVerbMU aid b "be disarmed"
        Effect.DropEqp _ False -> actorVerbMU aid b "be stripped"  -- TODO
        Effect.DropEqp _ True -> actorVerbMU aid b "be violently stripped"
        Effect.SendFlying{} -> actorVerbMU aid b "be sent flying"
        Effect.PushActor{} -> actorVerbMU aid b "be pushed"
        Effect.PullActor{} -> actorVerbMU aid b "be pulled"
        Effect.Teleport t | t > 9 -> actorVerbMU aid b "teleport"
        Effect.Teleport{} -> actorVerbMU aid b "blink"
        Effect.PolyItem cstore -> do
          allAssocs <- fullAssocsClient aid [cstore]
          case allAssocs of
            [] -> return ()  -- invisible items?
            (_, ItemFull{..}) : _ -> do
              let itemSecret = itemNoDisco (itemBase, itemK)
                  (secretName, secretAEText) = partItem cstore itemSecret
                  subject = partActor b
                  verb = "repurpose"
                  store = MU.Text $ ppCStore cstore
              msgAdd $ makeSentence
                [ MU.SubjectVerbSg subject verb
                , "the", secretName, secretAEText, store ]
        Effect.Identify cstore -> do
          allAssocs <- fullAssocsClient aid [cstore]
          case allAssocs of
            [] -> return ()  -- invisible items?
            (_, ItemFull{..}) : _ -> do
              let itemSecret = itemNoDisco (itemBase, itemK)
                  (secretName, secretAEText) = partItem cstore itemSecret
                  subject = partActor b
                  verb = "compare"
                  store = MU.Text $ ppCStore cstore
              msgAdd $ makeSentence
                [ MU.SubjectVerbSg subject verb
                , "old notes with the", secretName, secretAEText, store ]
        Effect.ActivateInv{} -> skip
        Effect.Explode{} -> skip  -- lots of visual feedback
        Effect.OneOf{} -> skip
        Effect.OnSmash{} -> assert `failure` sfx
        Effect.Timeout{} -> assert `failure` sfx
        Effect.TimedAspect{} -> skip  -- TODO
  SfxMsgFid _ msg -> msgAdd msg
  SfxMsgAll msg -> msgAdd msg
  SfxActorStart aid -> do
    arena <- getArenaUI
    b <- getsState $ getActorBody aid
    activeItems <- activeItemsClient aid
    when (blid b == arena) $ do
      -- If time clip has passed since any actor advanced level time
      -- or if the actor is so fast that he was capable of already moving
      -- this clip (for simplicity, we don't check if he actually did)
      -- or if the actor is newborn or is about to die,
      -- we end the frame early, before his current move.
      -- In the result, he moves at most once per frame, and thanks to this,
      -- his multiple moves are not collapsed into one frame.
      -- If the actor changes his speed this very clip, the test can faii,
      -- but it's rare and results in a minor UI issue, so we don't care.
      timeCutOff <- getsClient $ EM.findWithDefault timeZero arena . sdisplayed
      when (btime b >= timeShift timeCutOff (Delta timeClip)
            || btime b >= timeShiftFromSpeed b activeItems timeCutOff
            || actorNewBorn b
            || actorDying b) $ do
        let ageDisp displayed = EM.insert arena (btime b) displayed
        modifyClient $ \cli -> cli {sdisplayed = ageDisp $ sdisplayed cli}
        -- If considerable time passed, show delay.
        let delta = btime b `timeDeltaToFrom` timeCutOff
        when (delta > Delta timeClip) displayDelay
        -- If key will be requested, don't show the frame, because during
        -- the request extra message may be shown, so the other frame is better.
        mleader <- getsClient _sleader
        fact <- getsState $ (EM.! bfid b) . sfactionD
        let underAI = isAIFact fact
        unless (Just aid == mleader && not underAI) $
          -- Something new is gonna happen on this level (otherwise we'd send
          -- @UpdAgeLevel@ later on, with a larger time increment),
          -- so show crrent game state, before it changes.
          displayPush

strike :: MonadClientUI m
       => ActorId -> ActorId -> ItemId -> HitAtomic -> m ()
strike source target iid hitStatus = assert (source /= target) $ do
  itemToF <- itemToFullClient
  sb <- getsState $ getActorBody source
  tb <- getsState $ getActorBody target
  spart <- partActorLeader source sb
  tpart <- partActorLeader target tb
  spronoun <- partPronounLeader source sb
  let itemFull = itemToF iid (1, [])
      verb = case itemDisco itemFull of
        Nothing -> "hit"  -- not identified
        Just ItemDisco{itemKind} -> iverbHit itemKind
      isOrgan = iid `EM.member` borgan sb
      partItemChoice = if isOrgan
                       then partItemWownW spronoun COrgan
                       else partItemAW CEqp
      msg HitClear = makeSentence $
        [MU.SubjectVerbSg spart verb, tpart]
        ++ if bproj sb
           then []
           else ["with", partItemChoice itemFull]
      msg (HitBlock n) =
        let sActs =
              if bproj sb
              then [ MU.SubjectVerbSg spart "connect" ]
              else [ MU.SubjectVerbSg spart "swing"
                   , partItemChoice itemFull ]
        in makeSentence [ MU.Phrase sActs MU.:> ", but"
                        , MU.SubjectVerbSg tpart "block"
                        , if n > 1 then "doggedly" else "partly"
                        ]
-- TODO: when other armor is in, etc.:
--      msg HitSluggish =
--        let adv = MU.Phrase ["sluggishly", verb]
--        in makeSentence $ [MU.SubjectVerbSg spart adv, tpart]
--                          ++ ["with", partItemChoice itemFull]
  msgAdd $ msg hitStatus
  let ps = (bpos tb, bpos sb)
      anim HitClear = twirlSplash ps Color.BrRed Color.Red
      anim (HitBlock 1) = blockHit ps Color.BrRed Color.Red
      anim (HitBlock _) = blockMiss ps
  animFrs <- animate (blid sb) $ anim hitStatus
  displayActorStart sb animFrs
