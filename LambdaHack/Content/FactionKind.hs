{-# LANGUAGE OverloadedStrings #-}
-- | Game factions (heroes, enemies, NPCs, etc.) for LambdaHack.
module Content.FactionKind ( cdefs ) where

import Game.LambdaHack.Content.FactionKind
import Game.LambdaHack.ContentDef

cdefs :: ContentDef FactionKind
cdefs = ContentDef
  { getSymbol = fsymbol
  , getName = fname
  , getFreq = ffreq
  , validate = fvalidate
  , content =
      [hero, monster]
  }
hero,        monster :: FactionKind

hero = FactionKind
  { fsymbol   = '@'
  , fname     = "hero"
  , ffreq     = [("hero", 1), ("playable", 50)]
  , fAiLeader = "fullAbility"
  , fAiMember = "meleeAdjacent"
  , fenemy    = ["monster"]
  , fally     = []
  , fspawn    = 0
  , fentry    = toEnum 1
  }

monster = FactionKind
  { fsymbol   = 'm'
  , fname     = "monster"
  , ffreq     = [("monster", 1), ("playable", 50)]
  , fAiLeader = "fullAbility"
  , fAiMember = "fullAbility"
  , fenemy    = ["hero"]
  , fally     = []
  , fspawn    = 50
  , fentry    = toEnum 3  -- doesn't matter
  }
