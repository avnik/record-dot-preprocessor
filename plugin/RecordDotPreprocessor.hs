{-# LANGUAGE RecordWildCards, ViewPatterns, NamedFieldPuns, TypeFamilies #-}
{- HLINT ignore "Use camelCase" -}

-- | Module containing the plugin.
module RecordDotPreprocessor(plugin) where

import Data.Generics.Uniplate.Data
import Data.List.Extra
import Data.Tuple.Extra
import Data.Maybe (listToMaybe)
import Control.Applicative (Alternative(..))
import Control.Monad (guard)
import Compat
import Bag
import qualified GHC
import qualified GhcPlugins as GHC
import SrcLoc
import TcEvidence
import Debug.Trace
import Outputable (pprTraceIt)


---------------------------------------------------------------------
-- PLUGIN WRAPPER

-- | GHC plugin.
plugin :: GHC.Plugin
plugin = GHC.defaultPlugin
    { GHC.parsedResultAction = \_cliOptions _modSummary x -> pure x{GHC.hpm_module = onModule <$> GHC.hpm_module x}
    , GHC.pluginRecompile = GHC.purePlugin
    }


---------------------------------------------------------------------
-- PLUGIN GUTS

setL :: SrcSpan -> GenLocated SrcSpan e -> GenLocated SrcSpan e
setL l (L _ x) = L l x

mod_records :: GHC.ModuleName
mod_records = GHC.mkModuleName "GHC.Records.Extra"

mod_identity :: GHC.ModuleName
mod_identity = GHC.mkModuleName "Data.Functor.Identity"

mod_maybe :: GHC.ModuleName
mod_maybe = GHC.mkModuleName "Data.Maybe"

-- Even if I postpone detecting C/Columnar, I wrote constants for it there
mod_beam :: GHC.ModuleName
mod_beam = GHC.mkModuleName "Database.Beam.Schema"

var_HasField, var_hasField, var_getField, var_setField, var_dot :: GHC.RdrName
var_HasField = GHC.mkRdrQual mod_records $ GHC.mkClsOcc "HasField"
var_hasField = GHC.mkRdrUnqual $ GHC.mkVarOcc "hasField"
var_getField = GHC.mkRdrQual mod_records $ GHC.mkVarOcc "getField"
var_setField = GHC.mkRdrQual mod_records $ GHC.mkVarOcc "setField"
var_dot = GHC.mkRdrUnqual $ GHC.mkVarOcc "."

var_Identity, var_runIdentity :: GHC.RdrName
var_Identity = GHC.mkRdrQual mod_identity $ GHC.mkClsOcc "Identity"
var_runIdentity = GHC.mkRdrQual mod_identity $ GHC.mkVarOcc "runIdentity"

var_Maybe :: GHC.RdrName
var_Maybe = GHC.mkRdrQual mod_maybe $ GHC.mkClsOcc "Maybe"

var_Columnar, var_Nullable, var_PrimaryKey :: GHC.RdrName
var_Columnar = GHC.mkRdrQual mod_beam $ GHC.mkClsOcc "Columnar"
var_Nullable = GHC.mkRdrQual mod_beam $ GHC.mkClsOcc "Nullable"
var_PrimaryKey = GHC.mkRdrQual mod_beam $ GHC.mkClsOcc "PrimaryKey"

onModule :: HsModule GhcPs -> HsModule GhcPs
onModule x = x { hsmodImports = onImports $ hsmodImports x
               , hsmodDecls = concatMap onDecl $ hsmodDecls x
               }


onImports :: [LImportDecl GhcPs] -> [LImportDecl GhcPs]
onImports = (++) $ qualifiedImplicitImport <$> [mod_records, mod_maybe, mod_identity, mod_beam]


{-
instance Z.HasField "name" (Company) (String) where hasField _r = (\_x -> _r{name=_x}, (name:: (Company) -> String) _r)

instance HasField "selector" Record Field where
    hasField r = (\x -> r{selector=x}, (name :: Record -> Field) r)
-}
instanceTemplate :: FieldOcc GhcPs -> HsType GhcPs -> HsType GhcPs -> Maybe GHC.RdrName -> InstDecl GhcPs
instanceTemplate selector record field tyVar = ClsInstD noE $ ClsInstDecl noE (HsIB noE typ) (unitBag has) [] [] [] Nothing
    where
        typ = case (field, tyVar) of
            ((HsAppTy _ a b), Just t) -> highOrder t
            _ -> simple

        simple = mkHsAppTys
            (noL (HsTyVar noE GHC.NotPromoted (noL var_HasField)))
            [noL (HsTyLit noE (HsStrTy GHC.NoSourceText (GHC.occNameFS $ GHC.occName $ unLoc $ rdrNameFieldOcc selector)))
            ,noL record
            ,noL field
            ]

        highOrder :: GHC.RdrName -> LHsType GhcPs
        highOrder t = pprTraceIt "high " $ mkHsAppTys 
            (noL (HsTyVar noE GHC.NotPromoted (noL var_HasField)))
            [noL (HsTyLit noE (HsStrTy GHC.NoSourceText (GHC.occNameFS $ GHC.occName $ unLoc $ rdrNameFieldOcc selector)))
            ,recordTransformed record
            ,(pprTraceIt "case" $ fieldTransformed t field) -- I keep debug traces for fields and final expression
            ]

        recordTransformed :: HsType GhcPs -> LHsType GhcPs 
        recordTransformed rt = maybe (noL rt) template $ fst <$> unApplyType rt
            where template r = mkHsAppTys (noL r) [noL $ HsTyVar noE GHC.NotPromoted (noL var_Identity)]

        fieldTransformed :: GHC.RdrName -> HsType GhcPs -> LHsType GhcPs
        fieldTransformed t ft = maybe (pprTraceIt "default " $ noL ft) template $ processPK <|> processNull <|> processType
            where template tv = noL $ HsParTy noE tv
                  processPK = do
                      (ft0, _) <- unApplyType ft
                      (l, r) <- unApplyType ft0
                      tn <- getTypeName l
                      guard $ tn `stringifyEq` "PrimaryKey"
                      return $ mkHsAppTys (noL $ HsTyVar noE GHC.NotPromoted (noL var_PrimaryKey))
                               [ noL r
                               ,(noL $ HsTyVar noE GHC.NotPromoted (noL var_Identity))]
                  processNull = do
                      (ft0, r0) <- unApplyType ft
                      (l, r) <- unApplyType ft0
                      tn <- getTypeName l
                      guard $ (tn `stringifyEq` "Columnar") || (tn `stringifyEq` "C")
                      p <- unparenthise r
                      (l1, r1) <- unApplyType p
                      tn1 <- getTypeName l1
                      guard $ tn1 `stringifyEq` "Nullable"
                      return $ mkHsAppTy (noL $ HsTyVar noE GHC.NotPromoted (noL var_Maybe)) (noL r0)
                  processType = do
                      (ft0, r0) <- unApplyType ft
                      (l, r) <- unApplyType ft0
                      tn <- getTypeName (pprTraceIt "pt" l)
                      guard $ (tn `stringifyEq` "Columnar") || (tn `stringifyEq` "C") 
                      ft' <- getTypeName r0 -- (pprTraceIt "r0" r0) -- Kludge
                      return $ (noL $ HsTyVar noE GHC.NotPromoted (noL (pprTraceIt "ft'" ft'))) 

                  replaceTypeVar :: GHC.RdrName -> GHC.RdrName -> HsType GhcPs -> LHsType GhcPs
                  replaceTypeVar t newt tvs = go (pprTraceIt "tvs" tvs)
                      where go :: HsType GhcPs -> LHsType GhcPs  
                            go next = case unApplyType next of
                                                Just (l, r) | getTypeName l == Just t -> mkHsAppTy (noL $ HsTyVar noE GHC.NotPromoted (noL newt)) $ go r
                                                Just (l, r) -> mkHsAppTy (noL l) $ go r
                                                Nothing -> noL tvs

                  stringifyEq :: GHC.RdrName -> String -> Bool
                  stringifyEq a s = (GHC.occNameFS $  GHC.rdrNameOcc a) == GHC.mkFastString s

        getTypeName :: HsType pass -> Maybe (IdP pass)
        getTypeName (HsTyVar _ _ name) = Just $ unLoc name
        getTypeName _ = Nothing

        unparenthise :: HsType GhcPs -> Maybe (HsType GhcPs)
        unparenthise (HsParTy _ p) = Just $ unLoc p
        unparenthise _ = Nothing

        unApplyType :: HsType GhcPs -> Maybe (HsType GhcPs, HsType GhcPs)
        unApplyType (HsAppTy _ l r) = Just ((unLoc l), (unLoc r))
        unApplyType _ = Nothing

        has :: LHsBindLR GhcPs GhcPs
        has = noL $ FunBind noE (noL var_hasField) (mg1 eqn) WpHole []
            where
                eqn = Match
                    { m_ext     = noE
                    , m_ctxt    = FunRhs (noL var_hasField) GHC.Prefix NoSrcStrict
                    , m_pats    = compat_m_pats [VarPat noE $ noL vR]
                    , m_grhss   = GRHSs noE [noL $ GRHS noE [] $ noL $ ExplicitTuple noE [noL $ Present noE set, noL $ Present noE get] GHC.Boxed] (noL $ EmptyLocalBinds noE)
                    }
                set = noL $ HsLam noE $ mg1 Match
                    { m_ext     = noE
                    , m_ctxt    = LambdaExpr
                    , m_pats    = compat_m_pats [VarPat noE $ noL vX]
                    , m_grhss   = GRHSs noE [noL $ GRHS noE [] $ noL update] (noL $ EmptyLocalBinds noE)
                    }
                update = RecordUpd noE (noL $ GHC.HsVar noE $ noL vR)
                    [noL $ HsRecField (noL (Unambiguous noE (rdrNameFieldOcc selector))) (noL $ GHC.HsVar noE $ noL vX) False]
                get = mkApp
                    (mkParen $ mkTypeAnn (noL $ GHC.HsVar noE $ rdrNameFieldOcc selector) (noL $ HsFunTy noE (noL record) (noL field)))
                    (noL $ GHC.HsVar noE $ noL vR)

        mg1 :: Match GhcPs (LHsExpr GhcPs) -> MatchGroup GhcPs (LHsExpr GhcPs)
        mg1 x = MG noE (noL [noL x]) GHC.Generated

        vR = GHC.mkRdrUnqual $ GHC.mkVarOcc "r"
        vX = GHC.mkRdrUnqual $ GHC.mkVarOcc "x"


onDecl :: LHsDecl GhcPs -> [LHsDecl GhcPs]
onDecl o@(L _ (GHC.TyClD _ x@DataDecl{ tcdTyVars = tyVars })) = o : inserts
    where
        inserts = [ noL $ InstD noE $ instanceTemplate field (unLoc record) (unbang typ) typParam
                  | (record, _, field, typ) <- fields]
        fields = nubOrdOn (\(_,_,x',_) -> GHC.occNameFS $ GHC.rdrNameOcc $ unLoc $ rdrNameFieldOcc x') $ getFields x
        hasC = any isC $ (\(_,_,_,t) -> t) <$> fields

        isC :: HsType GhcPs -> Bool
        isC (HsAppTy _ b c) = True
        isC _ = False
        typParam = listToMaybe $ pprTraceIt "all" $ hsAllLTyVarNames' tyVars
onDecl x = [descendBi onExp x]

-- All variables (borrowed from GHC master)
hsAllLTyVarNames' :: LHsQTyVars GhcPs -> [GHC.RdrName]
hsAllLTyVarNames' (HsQTvs { hsq_ext = kvs
                          , hsq_explicit = tvs })
                 = hsLTyVarName <$> tvs

-- Debug tool -- like pprTraceIt, but show HsType constructor name
pprTraceTypeOf :: String -> HsType GhcPs -> HsType GhcPs
pprTraceTypeOf s a = pprTraceIt (s ++ " " ++ guessHsType a) a

-- Debug tool, explain what constructir whe have
guessHsType :: HsType GhcPs -> String
guessHsType (HsQualTy _ _ _) = "HsQualTy"
guessHsType (HsTyVar _ _ _) = "HsTyVar"
guessHsType (HsAppTy _ _ _) = "HsAppTy"
guessHsType (HsFunTy _ _ _) = "HsFunTy"
guessHsType (HsAppKindTy _ _ _) = "HsAppKindTy"
guessHsType (HsTupleTy _ _ _) = "HsTupleTy"
guessHsType (HsListTy _ _) = "HsListTy"
guessHsType (HsSumTy _ _) = "HsSumTy"
guessHsType _ = "unknown, I am too lazy "

unbang :: HsType GhcPs -> HsType GhcPs
unbang (HsBangTy _ _ x) = unLoc x
unbang x = x

getFields :: TyClDecl GhcPs -> [(LHsType GhcPs, IdP GhcPs, FieldOcc GhcPs, HsType GhcPs)]
getFields DataDecl{tcdDataDefn=HsDataDefn{..}, ..} = concatMap ctor dd_cons
    where
        ctor (L _ ConDeclH98{con_args=RecCon (L _ fields),con_name=L _ name}) = concatMap (field name) fields
        ctor (L _ ConDeclGADT{con_args=RecCon (L _ fields),con_names=names}) = concat [field name fld | L _ name <- names, fld <- fields]
        ctor _ = []

        field name (L _ ConDeclField{cd_fld_type=L _ ty, ..}) = [(result, name, fld, ty) | L _ fld <- cd_fld_names]
        field _ _ = error "unknown field declaration in getFields"

        -- A value of this data declaration will have this type.
        result = foldl (\x y -> noL $ HsAppTy noE x $ hsLTyVarBndrToType y) (noL $ HsTyVar noE GHC.NotPromoted tcdLName) $ hsq_explicit tcdTyVars
getFields _ = []


-- At this point infix expressions have not had associativity/fixity applied, so they are bracketed
-- a + b + c ==> (a + b) + c
-- Therefore we need to deal with, in general:
-- x.y, where
-- x := a | a b | a.b | a + b
-- y := a | a b | a{b=1}
onExp :: LHsExpr GhcPs -> LHsExpr GhcPs
onExp (L o (OpApp _ lhs mid@(isDot -> True) rhs))
    | adjacent lhs mid, adjacent mid rhs
    , (lhsOp, lhs) <- getOpRHS $ onExp lhs
    , (lhsApp, lhs) <- getAppRHS lhs
    , (rhsApp, rhs) <- getAppLHS rhs
    , (rhsRec, rhs) <- getRec rhs
    , Just sel <- getSelector rhs
    = onExp $ setL o $ lhsOp $ rhsApp $ lhsApp $ rhsRec $ mkParen $ mkVar var_getField `mkAppType` sel `mkApp` lhs

-- Turn (.foo.bar) into getField calls
onExp (L o (SectionR _ mid@(isDot -> True) rhs))
    | adjacent mid rhs
    , srcSpanStart o == srcSpanStart (getLoc mid)
    , srcSpanEnd o == srcSpanEnd (getLoc rhs)
    , Just sels <- getSelectors rhs
    -- Don't bracket here. The argument came in as a section so it's
    -- already enclosed in brackets.
    = setL o $ foldl1 (\x y -> noL $ OpApp noE x (mkVar var_dot) y) $ map (mkVar var_getField `mkAppType`) $ reverse sels

-- Turn a{b=c, ...} into setField calls
onExp (L o upd@RecordUpd{rupd_expr,rupd_flds=fld:flds})
    | adjacentBy 1 rupd_expr fld
    = onExp $ f rupd_expr $ fld:flds
    where
        f expr [] = expr
        f expr (L _ (HsRecField (fmap rdrNameAmbiguousFieldOcc -> lbl) arg pun) : flds)
            | let sel = mkSelector lbl
            , let arg2 = if pun then noL $ HsVar noE lbl else arg
            , let expr2 = mkParen $ mkVar var_setField `mkAppType` sel `mkApp` expr `mkApp` arg2  -- 'expr' never needs bracketing.
            = f expr2 flds

onExp x = descend onExp x


mkSelector :: Located GHC.RdrName -> LHsType GhcPs
mkSelector (L o x) = L o $ HsTyLit noE $ HsStrTy GHC.NoSourceText $ GHC.occNameFS $ GHC.rdrNameOcc x

getSelector :: LHsExpr GhcPs -> Maybe (LHsType GhcPs)
getSelector (L _ (HsVar _ (L o sym)))
    | not $ GHC.isQual sym
    = Just $ mkSelector $ L o sym
getSelector _ = Nothing

-- | Turn a.b.c into Just [a,b,c]
getSelectors :: LHsExpr GhcPs -> Maybe [LHsType GhcPs]
getSelectors (L _ (OpApp _ lhs mid@(isDot -> True) rhs))
    | adjacent lhs mid, adjacent mid rhs
    , Just post <- getSelector rhs
    , Just pre <- getSelectors lhs
    = Just $ pre ++ [post]
getSelectors x = (:[]) <$> getSelector x

-- | Lens on: f [x]
getAppRHS :: LHsExpr GhcPs -> (LHsExpr GhcPs -> LHsExpr GhcPs, LHsExpr GhcPs)
getAppRHS (L l (HsApp e x y)) = (L l . HsApp e x, y)
getAppRHS x = (id, x)

-- | Lens on: [f] x y z
getAppLHS :: LHsExpr GhcPs -> (LHsExpr GhcPs -> LHsExpr GhcPs, LHsExpr GhcPs)
getAppLHS (L l (HsApp e x y)) = first (\c -> L l . (\x -> HsApp e x y) . c) $ getAppLHS x
getAppLHS x = (id, x)

-- | Lens on: a + [b]
getOpRHS :: LHsExpr GhcPs -> (LHsExpr GhcPs -> LHsExpr GhcPs, LHsExpr GhcPs)
getOpRHS (L l (OpApp x y p z)) = (L l . OpApp x y p, z)
getOpRHS x = (id, x)

-- | Lens on: [r]{f1=x1}{f2=x2}
getRec :: LHsExpr GhcPs -> (LHsExpr GhcPs -> LHsExpr GhcPs, LHsExpr GhcPs)
-- important to copy the location back over, since we check the whitespace hasn't changed
getRec (L l r@RecordUpd{}) = first (\c x -> L l r{rupd_expr=setL (getLoc $ rupd_expr r) $ c x}) $ getRec $ rupd_expr r
getRec x = (id, x)

-- | Is it equal to: .
isDot :: LHsExpr GhcPs -> Bool
isDot (L _ (HsVar _ (L _ op))) = op == var_dot
isDot _ = False

mkVar :: GHC.RdrName -> LHsExpr GhcPs
mkVar = noL . HsVar noE . noL

mkParen :: LHsExpr GhcPs -> LHsExpr GhcPs
mkParen = noL . HsPar noE

mkApp :: LHsExpr GhcPs -> LHsExpr GhcPs -> LHsExpr GhcPs
mkApp x y = noL $ HsApp noE x y

-- | Are the end of a and the start of b next to each other, no white space
adjacent :: Located a -> Located b -> Bool
adjacent = adjacentBy 0

-- | Are the end of a and the start of b next to each other, no white space
adjacentBy :: Int -> Located a -> Located b -> Bool
adjacentBy i (L (srcSpanEnd -> RealSrcLoc a) _) (L (srcSpanStart -> RealSrcLoc b) _) =
    srcLocFile a == srcLocFile b &&
    srcLocLine a == srcLocLine b &&
    srcLocCol a + i == srcLocCol b
adjacentBy _ _ _ = False
