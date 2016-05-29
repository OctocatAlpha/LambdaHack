-- | Binding of keys to commands.
-- No operation in this module involves the 'State' or 'Action' type.
module Game.LambdaHack.Client.UI.KeyBindings
  ( Binding(..), stdBinding, keyHelp
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.Map.Strict as M
import qualified Data.Text as T

import qualified Game.LambdaHack.Client.Key as K
import Game.LambdaHack.Client.UI.Config
import Game.LambdaHack.Client.UI.Content.KeyKind
import Game.LambdaHack.Client.UI.HumanCmd
import Game.LambdaHack.Client.UI.Overlay
import Game.LambdaHack.Client.UI.Slideshow

-- | Bindings and other information about human player commands.
data Binding = Binding
  { bcmdMap  :: !(M.Map K.KM CmdTriple)   -- ^ binding of keys to commands
  , bcmdList :: ![(K.KM, CmdTriple)]      -- ^ the properly ordered list
                                          --   of commands for the help menu
  , brevMap  :: !(M.Map HumanCmd [K.KM])  -- ^ and from commands to their keys
  }

-- | Binding of keys to movement and other standard commands,
-- as well as commands defined in the config file.
stdBinding :: KeyKind  -- ^ default key bindings from the content
           -> Config   -- ^ game config
           -> Binding  -- ^ concrete binding
stdBinding copsClient !Config{configCommands, configVi, configLaptop} =
  let waitTriple = ([CmdMove], "", Wait)
      moveXhairOr n cmd v = ByAimMode { notAiming = cmd v
                                      , aiming = MoveXhair v n }
      cmdAll =
        rhumanCommands copsClient
        ++ configCommands
        ++ [ (K.mkKM "KP_Begin", waitTriple)
           , (K.mkKM "CTRL-KP_Begin", waitTriple)
           , (K.mkKM "KP_5", waitTriple)
           , (K.mkKM "CTRL-KP_5", waitTriple) ]
        ++ (if | configVi ->
                 [ (K.mkKM "period", waitTriple) ]
               | configLaptop ->
                 [ (K.mkKM "i", waitTriple)
                 , (K.mkKM "I", waitTriple) ]
               | otherwise ->
                 [])
        ++ K.moveBinding configVi configLaptop
             (\v -> ([CmdMove], "", moveXhairOr 1 MoveDir v))
             (\v -> ([CmdMove], "", moveXhairOr 10 RunDir v))
  in Binding
  { bcmdMap = M.fromList cmdAll
  , bcmdList = cmdAll
  , brevMap = M.fromListWith (flip (++)) $ concat
      [ [(cmd, [k])]
      | (k, (cats, _desc, cmd)) <- cmdAll
      , all (`notElem` [CmdMainMenu, CmdSettingsMenu, CmdDebug, CmdInternal])
            cats
      ]
  }

-- | Produce a set of help screens from the key bindings.
keyHelp :: Binding -> Int -> [(Text, OKX)]
keyHelp Binding{..} offset = assert (offset > 0) $
  let
    movBlurb =
      [ ""
      , "Walk throughout a level with mouse or numeric keypad (left diagram)"
      , "or its compact laptop replacement (middle) or the Vi text editor keys"
      , "(right, also known as \"Rogue-like keys\"; can be enabled in config.ui.ini)."
      , "Run, until disturbed, with LMB (left mouse button) or SHIFT/CTRL and a key."
      , ""
      , "               7 8 9          7 8 9          y k u"
      , "                \\|/            \\|/            \\|/"
      , "               4-5-6          u-i-o          h-.-l"
      , "                /|\\            /|\\            /|\\"
      , "               1 2 3          j k l          b j n"
      , ""
      , "In aiming mode (KEYPAD_* or !) the same keys (or mouse) move the crosshair."
      , "Press 'KEYPAD_5' (or 'i' or '.') to wait, bracing for blows, which reduces"
      , "any damage taken and makes it impossible for foes to displace you."
      , "You displace enemies or friends by bumping into them with SHIFT (or CTRL)."
      , ""
      , "Search, loot, open and attack by bumping into walls, doors and enemies."
      , "The best item to attack with is automatically chosen from among"
      , "weapons in your personal equipment and your unwounded organs."
      , ""
      , "Press SPACE to see the minimal command set."
      ]
    minimalBlurb =
      [ "The following minimal command set lets you accomplish anything in the game,"
      , "though not necessarily with the fewest number of keystrokes."
      , "Most of the other commands are shorthands, defined as macros"
      , "(with the exception of the advanced commands for assigning non-default"
      , "tactics and targets to your autonomous henchmen, if you have any)."
      , ""
      ]
    casualEndBlurb =
      [ ""
      , "Press SPACE to see the detailed descriptions of all commands."
      ]
    categoryBlurb =
      [ ""
      , "Press SPACE to see the next page of command descriptions."
      ]
    lastBlurb =
      [ ""
      , "For more playing instructions see file PLAYING.md."
      , "Press PGUP to return to previous pages"
      , "and SPACE or ESC to see the map again."
      ]
    pickLeaderDescription =
      [ fmt 12 "0, 1 ... 6" "pick a particular actor as the new leader"
      ]
    casualDescription = "Minimal cheat sheet for casual play"
    fmt n k h = T.justifyRight 72 ' '
                $ T.justifyLeft n ' ' k
                  <+> T.justifyLeft 48 ' ' h
    fmts s = " " <> T.justifyLeft 71 ' ' s
    movText = map fmts movBlurb
    minimalText = map fmts minimalBlurb
    casualEndText = map fmts casualEndBlurb
    categoryText = map fmts categoryBlurb
    lastText = map fmts lastBlurb
    coImage :: HumanCmd -> [K.KM]
    coImage cmd = M.findWithDefault (assert `failure` cmd) cmd brevMap
    disp cmd = T.concat $ intersperse " or " $ map K.showKM $ coImage cmd
    keysN n cat = [ (Left k, fmt n (disp cmd) desc)
                  | (k, (cats, desc, cmd)) <- bcmdList
                  , cat `elem` cats
                  , desc /= "" ]
    -- TODO: measure the longest key sequence and set the caption automatically
    keyCaptionN n = fmt n "keys" "command"
    keyCaption = keyCaptionN 12
    okxsN :: Int -> CmdCategory -> [Text] -> [Text] -> OKX
    okxsN n cat header footer =
      let (ks, keyTable) = unzip $ keysN n cat
          kxs = zip ks [(y, 0, maxBound) | y <- [offset + length header..]]
      in (map toAttrLine $ fmts "" : header ++ keyTable ++ footer, kxs)
    okxs = okxsN 12
  in
    [ ( ""  -- the first screen is for ItemMenu
      , okxs CmdItemMenu [keyCaption] [] )
    , ( casualDescription <+> "(1/2)."
      , (map toAttrLine $ movText, []) )
    , ( casualDescription <+> "(2/2)."
      , okxs CmdMinimal (minimalText ++ [keyCaption]) casualEndText )
    , ( "All terrain exploration and alteration commands."
      , okxs CmdMove [keyCaption] categoryText )
    , ( categoryDescription CmdItem <> "."
      , okxs CmdItem [keyCaption] categoryText )
    , ( categoryDescription CmdAim <> "."
      , okxs CmdAim [keyCaption] categoryText )
    , ( categoryDescription CmdMeta <> "."
      , okxs CmdMeta [keyCaption] (pickLeaderDescription ++ categoryText) )
    , ( categoryDescription CmdMouse <> "."
      , let (ov, _) = okxs CmdMouse [keyCaption] lastText
        in (ov, []) )
    ]
