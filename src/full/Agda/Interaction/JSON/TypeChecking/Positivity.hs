{-# LANGUAGE OverloadedStrings #-}

-- | Instances of EncodeTCM or ToJSON under Agda.TypeChecking.Positivity

module Agda.Interaction.JSON.TypeChecking.Positivity where

import Data.Aeson
import Data.Foldable (toList)

import Agda.Interaction.JSON.Encode
import Agda.Interaction.JSON.Syntax.Abstract.Name
-- import Agda.Interaction.JSON.Syntax.Concrete.Name
import Agda.Interaction.JSON.Syntax.Position
import Agda.TypeChecking.Positivity.Occurrence
import qualified Agda.Syntax.Translation.AbstractToConcrete as A2C

--------------------------------------------------------------------------------

instance EncodeTCM OccursWhere where
  encodeTCM Unknown               = kind "Unknown" []
  encodeTCM (Known range wheres)  = kind "Known"
    [ "range"       @= range
    , "wheres"      @= (toList wheres)
    ]

instance EncodeTCM Where where
  encodeTCM LeftOfArrow           = kind "LeftOfArrow" []
  encodeTCM (DefArg name n)       = kind "DefArg"
    [ "name"        @= name
    , "index"       @= n
    ]
  encodeTCM UnderInf              = kind "UnderInf" []
  encodeTCM VarArg                = kind "VarArg" []
  encodeTCM MetaArg               = kind "MetaArg" []
  encodeTCM (ConArgType name)     = kind "ConArgType"
    [ "name"        @= name
    ]
  encodeTCM (IndArgType name)     = kind "IndArgType"
    [ "name"        @= name
    ]
  encodeTCM (InClause n)          = kind "InClause"
    [ "index"       @= n
    ]
  encodeTCM Matched               = kind "Matched" []
  encodeTCM (InDefOf name)        = kind "InDefOf"
    [ "name"        @= name
    ]


instance ToJSON Occurrence where
  toJSON Mixed      = String "Mixed"
  toJSON JustNeg    = String "JustNeg"
  toJSON JustPos    = String "JustPos"
  toJSON StrictPos  = String "StrictPos"
  toJSON GuardPos   = String "GuardPos"
  toJSON Unused     = String "Unused"