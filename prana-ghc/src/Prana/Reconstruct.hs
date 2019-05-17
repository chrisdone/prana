{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | Reconstruct the AST by taking the GHC STG AST and producing
-- Prana's own ASt.

module Prana.Reconstruct
  ( fromGenStgTopBinding
  , runConvert
  , Scope(..)
  , ConvertError (..)
  , failure
  ) where

import           Control.Exception
import           Control.Monad.Reader
import qualified CoreSyn
import qualified Data.ByteString.Char8 as S8
import           Data.List.NonEmpty (NonEmpty(..))
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Maybe
import           Data.Typeable
import           Data.Validation
import qualified DataCon
import qualified Literal
import qualified Module
import           Prana.Index
import           Prana.Rename
import           Prana.Types
import qualified PrimOp
import qualified StgSyn
import           Text.Read
import qualified TyCoRep
import qualified TyCon
import           TysWiredIn

-- | A conversion monad.
newtype Convert a =
  Convert
    { runConvert :: ReaderT Scope (Validation (NonEmpty ConvertError)) a
    }
  deriving (Functor, Applicative)

-- | An error while converting the AST.
data ConvertError
  = UnexpectedPolymorphicCaseAlts
  | UnexpectedLambda
  | ConNameNotFound !Name
  | GlobalNameNotFound !Name
  | LocalNameNotFound !Name
  | SomeNameNotFound !Name
  | RenameDataConError !DataCon.DataCon !RenameFailure
  | RenameFailure !RenameFailure
  | BadOpConversion !PrimOp.PrimOp
  deriving (Eq, Typeable)

instance Exception ConvertError where
  displayException =
    \case
      SomeNameNotFound name -> "Variable name not found: " <> displayName name
      LocalNameNotFound name -> "Local variable name not found: " <> displayName name
      GlobalNameNotFound name -> "Global variable name not found: " <> displayName name
      ConNameNotFound name -> "Constructor name not found: " <> displayName name
      orelse -> show orelse

instance Show ConvertError where
  show UnexpectedPolymorphicCaseAlts {} = "UnexpectedPolymorphicCaseAlts"
  show UnexpectedLambda {} = "UnexpectedLambda"
  show (ConNameNotFound name) = "ConNameNotFound " ++ show name
  show (LocalNameNotFound name) = "LocalNameNotFound " ++ show name
  show (GlobalNameNotFound name) = "GlobalNameNotFound " ++ show name
  show (SomeNameNotFound name) = "SomeNameNotFound " ++ show name
  show RenameDataConError {} = "RenameDataConError"
  show RenameFailure {} = "RenameFailure"
  show (BadOpConversion primop) = "BadOpConversion " ++ show primop

data Scope =
  Scope
    { scopeIndex :: !Index
    , scopeModule :: !Module.Module
    }

-- | Produce a failure.
failure :: ConvertError -> Convert a
failure e = Convert (ReaderT (\_ -> Failure (pure e)))

--------------------------------------------------------------------------------
-- Conversion functions

fromGenStgTopBinding :: StgSyn.GenStgTopBinding Name Name -> Convert GlobalBinding
fromGenStgTopBinding =
  \case
    StgSyn.StgTopLifted genStdBinding ->
      case genStdBinding of
        StgSyn.StgNonRec bindr rhs ->
          GlobalNonRec <$> lookupGlobalVarId bindr <*> fromGenStgRhs rhs
        StgSyn.StgRec pairs ->
          GlobalRec <$>
          traverse
            (\(bindr, rhs) -> (,) <$> lookupGlobalVarId bindr <*> fromGenStgRhs rhs)
            pairs
    StgSyn.StgTopStringLit bindr byteString ->
      GlobalStringLit <$> lookupGlobalVarId bindr <*> pure byteString

fromGenStgBinding :: StgSyn.GenStgBinding Name Name -> Convert LocalBinding
fromGenStgBinding =
  \case
    StgSyn.StgNonRec bindr rhs ->
      LocalNonRec <$> lookupLocalVarId bindr <*> fromGenStgRhs rhs
    StgSyn.StgRec pairs ->
      LocalRec <$>
      traverse
        (\(bindr, rhs) -> (,) <$> lookupLocalVarId bindr <*> fromGenStgRhs rhs)
        pairs

fromGenStgRhs :: StgSyn.GenStgRhs Name Name -> Convert Rhs
fromGenStgRhs =
  \case
    StgSyn.StgRhsClosure _costCentreStack _binderInfo freeVariables updateFlag parameters expr ->
      RhsClosure <$>
      (Closure <$> traverse lookupLocalVarId freeVariables <*>
       pure
         (case updateFlag of
            StgSyn.ReEntrant -> ReEntrant
            StgSyn.Updatable -> Updatable
            StgSyn.SingleEntry -> SingleEntry) <*>
       traverse lookupLocalVarId parameters <*>
       fromStgGenExpr expr)
    StgSyn.StgRhsCon _costCentreStack dataCon arguments ->
      RhsCon <$> (Con <$> lookupDataConId dataCon <*> traverse fromStgGenArg arguments)

fromStgGenArg :: StgSyn.GenStgArg Name -> Convert Arg
fromStgGenArg =
  \case
    StgSyn.StgVarArg occ -> VarArg <$> lookupSomeVarId occ
    StgSyn.StgLitArg literal ->
      pure
        (LitArg
           (fromLiteral literal))

fromLiteral :: Literal.Literal -> Lit
fromLiteral =
  \case
    Literal.MachInt integer -> IntLit (fromIntegral integer) -- TODO: Is this cromulent?
    Literal.MachChar chareger -> CharLit (chareger)
    _ -> UnknownLit

fromStgGenExpr :: StgSyn.GenStgExpr Name Name -> Convert Expr
fromStgGenExpr =
  \case
    StgSyn.StgApp occ arguments ->
      AppExpr <$> lookupSomeVarId occ <*> traverse fromStgGenArg arguments
    StgSyn.StgLit literal -> LitExpr <$> pure (fromLiteral literal)
    StgSyn.StgConApp dataCon arguments types ->
      ConAppExpr <$> lookupDataConId dataCon <*> traverse fromStgGenArg arguments <*>
      pure (map (const Type) types)
    StgSyn.StgOpApp stgOp arguments typ ->
      OpAppExpr <$> fromStgOp stgOp <*> traverse fromStgGenArg arguments <*>
      pure (opTypeFromType typ)
    StgSyn.StgCase expr bndr altType alts ->
      CaseExpr <$> fromStgGenExpr expr <*> lookupLocalVarId bndr <*>
      case altType of
        StgSyn.PolyAlt
          | [(CoreSyn.DEFAULT, [], rhs)] <- alts ->
            PolymorphicAlt <$> fromStgGenExpr rhs
          | otherwise -> failure UnexpectedPolymorphicCaseAlts
        StgSyn.MultiValAlt count ->
          (\(mdef, dataAlts) -> MultiValAlts count dataAlts mdef) <$>
          fromAltTriples alts
        StgSyn.AlgAlt tyCon -> do
          (\(mdef, dataAlts) -> DataAlts (const TyCon tyCon) dataAlts mdef) <$>
            fromAltTriples alts
        StgSyn.PrimAlt primRep -> do
          (\(mdef, primAlts) -> PrimAlts (fromPrimRep primRep) primAlts mdef) <$>
            fromPrimAltTriples alts
    StgSyn.StgLet binding expr ->
      LetExpr <$> fromGenStgBinding binding <*> fromStgGenExpr expr
    StgSyn.StgLetNoEscape binding expr ->
      LetExpr <$> fromGenStgBinding binding <*> fromStgGenExpr expr
    StgSyn.StgTick _tickish expr -> fromStgGenExpr expr
    StgSyn.StgLam {} -> failure UnexpectedLambda

opTypeFromType :: TyCoRep.Type -> PrimOpType
opTypeFromType =
  \case
    TyCoRep.TyConApp tyCon []
      | tyCon == TysWiredIn.boolTyCon -> BoolType
    _ -> UnknownType

fromStgOp :: StgSyn.StgOp -> Convert Op
fromStgOp =
  \case
     StgSyn.StgPrimOp op -> PrimOp <$> fromPrimOp op
     _ -> pure OtherOp

deriving instance Show PrimOp.PrimOp
deriving instance Show PrimOp.PrimOpVecCat

-- | The constructor names are the same.
fromPrimOp :: PrimOp.PrimOp -> Convert PrimOp
fromPrimOp op =
  case readMaybe (show op) of
    Nothing -> failure (BadOpConversion op)
    Just pr -> pure pr

fromPrimRep :: TyCon.PrimRep -> PrimRep
fromPrimRep =
  \case
    TyCon.VoidRep -> VoidRep
    TyCon.LiftedRep -> LiftedRep
    TyCon.UnliftedRep -> UnliftedRep
    TyCon.IntRep -> IntRep
    TyCon.WordRep -> WordRep
    TyCon.Int64Rep -> Int64Rep
    TyCon.Word64Rep -> Word64Rep
    TyCon.AddrRep -> AddrRep
    TyCon.FloatRep -> FloatRep
    TyCon.DoubleRep -> DoubleRep
    TyCon.VecRep size primElemRep -> VecRep size (fromPrimElemRep primElemRep)

fromPrimElemRep :: TyCon.PrimElemRep -> PrimElemRep
fromPrimElemRep =
  \case
    TyCon.Int8ElemRep -> Int8ElemRep
    TyCon.Int16ElemRep -> Int16ElemRep
    TyCon.Int32ElemRep -> Int32ElemRep
    TyCon.Int64ElemRep -> Int64ElemRep
    TyCon.Word8ElemRep -> Word8ElemRep
    TyCon.Word16ElemRep -> Word16ElemRep
    TyCon.Word32ElemRep -> Word32ElemRep
    TyCon.Word64ElemRep -> Word64ElemRep
    TyCon.FloatElemRep -> FloatElemRep
    TyCon.DoubleElemRep -> DoubleElemRep

fromAltTriples :: [StgSyn.GenStgAlt Name Name] -> Convert (Maybe Expr, [DataAlt])
fromAltTriples alts = do
  let mdef =
        listToMaybe
          (mapMaybe
             (\case
                (CoreSyn.DEFAULT, [], e) -> Just e
                _ -> Nothing)
             alts)
      adtAlts =
        mapMaybe
          (\case
             (CoreSyn.DataAlt dc, bs, e) -> pure (dc, bs, e)
             _ -> Nothing)
          alts
  (,) <$> maybe (pure Nothing) (fmap Just . fromStgGenExpr) mdef <*>
    traverse
      (\(dc, bs, e) ->
         DataAlt <$> lookupDataConId dc <*> traverse lookupLocalVarId bs <*>
         fromStgGenExpr e)
      adtAlts

fromPrimAltTriples :: [StgSyn.GenStgAlt Name Name] -> Convert (Maybe Expr, [LitAlt])
fromPrimAltTriples alts = do
  let mdef =
        listToMaybe
          (mapMaybe
             (\case
                (CoreSyn.DEFAULT, [], e) -> Just e
                _ -> Nothing)
             alts)
      adtAlts =
        mapMaybe
          (\case
             (CoreSyn.LitAlt dc, bs, e) -> pure (dc, bs, e)
             _ -> Nothing)
          alts
  (,) <$> maybe (pure Nothing) (fmap Just . fromStgGenExpr) mdef <*>
    traverse
      (\(dc, bs, e) ->
         LitAlt <$> pure (fromLiteral dc) <*> traverse lookupLocalVarId bs <*>
         fromStgGenExpr e)
      adtAlts

--------------------------------------------------------------------------------
-- Lookup functions

lookupSomeVarId :: Name -> Convert SomeVarId
lookupSomeVarId name =
  asking
    (\scope ->
       case M.lookup name wiredInVals of
         Just wiredIn -> pure (WiredInVal wiredIn)
         Nothing ->
           case M.lookup name (indexGlobals (scopeIndex scope)) of
             Nothing ->
               case M.lookup name (indexLocals (scopeIndex scope)) of
                 Nothing -> Failure (pure (SomeNameNotFound name))
                 Just g -> pure (SomeLocalVarId g)
             Just g -> pure (SomeGlobalVarId g))

lookupGlobalVarId :: Name -> Convert GlobalVarId
lookupGlobalVarId name =
  asking
    (\scope ->
       case M.lookup name (indexGlobals (scopeIndex scope)) of
         Nothing -> Failure (pure (GlobalNameNotFound name))
         Just g -> pure g)

lookupLocalVarId :: Name -> Convert LocalVarId
lookupLocalVarId name =
  asking
    (\scope ->
       case M.lookup name (indexLocals (scopeIndex scope)) of
         Nothing -> Failure (pure (LocalNameNotFound name))
         Just g -> pure g)

lookupDataConId :: DataCon.DataCon -> Convert DataConId
lookupDataConId dataCon =
  asking
    (\scope ->
       either
         (Failure . pure . RenameDataConError dataCon)
         (\name ->
            case M.lookup name unboxedTupleCons of
              Just wiredCon -> pure wiredCon
              Nothing ->
                case M.lookup name (indexDataCons (scopeIndex scope)) of
                  Nothing -> Failure (pure (ConNameNotFound name))
                  Just g -> pure g)
         (renameId (scopeModule scope) (DataCon.dataConWorkId dataCon)))

-- | A way of injecting @ask@ into the Applicative.
asking :: (Scope -> Validation (NonEmpty ConvertError) a) -> Convert a
asking f = Convert (ReaderT f)

--------------------------------------------------------------------------------
-- Wired-in names

wiredInVals :: Map Name WiredInVal
wiredInVals =
  M.fromList
    [ ( Name
          { namePackage = "ghc-prim"
          , nameModule = "GHC.Prim"
          , nameName = "magicDict"
          , nameUnique = Exported
          }
      , WiredIn_magicDict),
      ( Name
          { namePackage = "ghc-prim"
          , nameModule = "GHC.Prim"
          , nameName = "void#"
          , nameUnique = Exported
          }
      , WiredIn_void#)
    , ( Name
          { namePackage = "ghc-prim"
          , nameModule = "GHC.Prim"
          , nameName = "coercionToken#"
          , nameUnique = Exported
          }
      , WiredIn_coercionToken#)
    , ( Name
          { namePackage = "ghc-prim"
          , nameModule = "GHC.Prim"
          , nameName = "realWorld#"
          , nameUnique = Exported
          }
      , WiredIn_realWorld#)
    ,  ( Name
           { namePackage = "ghc-prim"
           , nameModule = "GHC.Prim"
           , nameName = "nullAddr#"
           , nameUnique = Exported
           }
       , WiredIn_nullAddr#)
    , ( Name
          { namePackage = "ghc-prim"
          , nameModule = "GHC.Prim"
          , nameName = "seq"
          , nameUnique = Exported
          }
      , WiredIn_seq)
    , ( Name
          { namePackage = "base"
          , nameModule = "Control.Exception.Base"
          , nameName = "patError"
          , nameUnique = Exported
          }
      , WiredIn_patError)
    ,  ( Name
           { namePackage = "ghc-prim"
           , nameModule = "GHC.Prim"
           , nameName = "proxy#"
           , nameUnique = Exported
           }
       , WiredIn_proxy#)
    ]

-- Notes on tuples.
-- Copied from the GHC codebase:

-- However the /naming/ of the type/data constructors for one-tuples is a
-- bit odd:
--   3-tuples:  (,,)   (,,)#
--   2-tuples:  (,)    (,)#
--   1-tuples:  ??
--   0-tuples:  ()     ()#

-- Zero-tuples have used up the logical name. So we use 'Unit' and 'Unit#'
-- for one-tuples.  So in ghc-prim:GHC.Tuple we see the declarations:
--   data ()     = ()
--   data Unit a = Unit a
--   data (a,b)  = (a,b)

unboxedTupleCons :: Map Name DataConId
unboxedTupleCons =
  M.fromList
    (concat
       [ [ ( Name
               { namePackage = "ghc-prim"
               , nameModule = "GHC.Prim"
               , nameName = "(##)"
               , nameUnique = Exported
               }
           , UnboxedTupleConId 0)
         , ( Name
               { namePackage = "ghc-prim"
               , nameModule = "GHC.Prim"
               , nameName = "Unit#"
               , nameUnique = Exported
               }
           , UnboxedTupleConId 1)
         ]
       , [ ( Name
               { namePackage = "ghc-prim"
               , nameModule = "GHC.Prim"
               , nameName = "(#" <> S8.replicate (n - 1) ',' <> "#)"
               , nameUnique = Exported
               }
           , UnboxedTupleConId n)
         | n <- [2 .. 64]
         ]
       ])
