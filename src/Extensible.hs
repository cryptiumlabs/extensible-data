{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE
    CPP, DeriveDataTypeable, DeriveLift, PatternSynonyms, StandaloneDeriving,
    TemplateHaskell
  #-}

-- | #maindoc#
-- Generates an extensible datatype from a datatype declaration, roughly
-- following the pattern given by the /Trees that Grow/ paper by Najd and
-- Peyton Jones.
--
--
-- * A type family is generated for each constructor, taking an argument named
--   @ext@ for the extension type, followed by the arguments of the datatype.
--   The names of the type families correspond to the constructors themselves
--   modified with 'annotationName' (see @<#XBar XBar>@ etc below).
-- * An extra type family is generated with the same arguments, named after the
--   datatype modified with 'extensionName' (see @<#FooX FooX>@).
-- * The datatype itself is renamed according to 'datatypeName' and given an
--   extra argument called @ext@ (before the others).
-- * Each existing constructor is renamed according to 'constructorName', and
--   given an extra strict field of the corresponding type family generated
--   above.
-- * An extra constructor is generated for the extension type family (with the
--   same name), containing it as its sole field (see @<#Foo' Foo'>@ for the
--   transformation).
-- * A constraint synonym is generated, named according to 'bundleName', which
--   contains a constraint for each extension (see @<#FooAll FooAll>@).
-- * A record and TH function are generated for creating new extensions of the
--   base datatype (see @<#FooExt FooExt>@ and @<#extendFoo extendFoo>@).
-- * A standalone @deriving@ declaration is generated for each derived instance
--   listed. __Note that this has some caveats__:
--
--     * Only @stock@ and @anyclass@ strategies are supported.
--     * __The context is not calculated properly like a real deriving clause__.
--       Instead, a constraint of the given class is required for each type
--       variable and each extension. If this doesn't work (e.g. you want to
--       derive 'Eq' but have a type variable of kind @'K.Type' -> 'K.Type'@), you
--       must instead write your own declaration outside of the call to
--       'extensible'.
--
-- Due to GHC's staging restriction, it is not possible to write
-- @'extensible' [d| data Foo = ... |]@ and use the generated @extendFoo@
-- function within the same module.
--
-- The module where @extensible@ is called needs the following extensions to be
-- enabled:
--
-- * @TemplateHaskell@,
-- * @TypeFamilies@,
-- * @FlexibleContexts@,
-- * @UndecidableInstances@,
-- * @ConstraintKinds@,
-- * @KindSignatures@, and
-- * @StandaloneDeriving@.
--
-- Modules calling @extendFoo@ need:
--
-- * @TemplateHaskell@,
-- * @TypeFamilies@, and
-- * @PatternSynonyms@.
--
-- You will probably also currently want to disable the warning for missing
-- @pattern@ type signatures (@-Wno-missing-pattern-synonym-signatures@).
--
-- == Example
--
-- @
-- module Foo.Base where #Foo_Base#
-- import Extensible
--
-- 'extensible' [d| data Foo a = Bar a | Baz (Foo a) (Foo 'Int') |]
--
-- ====>
--
-- type family XBar ext a #XBar#
-- type family XBaz ext a #XBaz#
-- type family FooX ext a #FooX#
--
-- data Foo' ext a = #Foo'#
--     Bar' a !(<#XBar XBar> ext a) #Bar'#
--   | Baz' (<#Foo' Foo'> ext a) (<#Foo' Foo'> ext 'Int') !(<#XBaz XBaz> ext a) #Baz'#
--   | FooX !(<#FooX FooX> ext a) #FooX#
--
-- -- ('K.Type' from "Data.Kind", not from TH!)
-- type FooAll (c :: 'K.Type' -> 'Constraint') ext a = #FooAll#
--   (c (<#XBar XBar> ext a),
--    c (<#XBaz XBaz> ext a),
--    c (<#FooX FooX> ext a))
--
-- data ExtFoo = ExtFoo { #ExtFoo#
--     nameBar  :: 'String',                        #nameBar#
--     typeBar  :: 'Maybe' ('TypeQ' -> 'TypeQ'),    #typeBar#
--     nameBaz  :: 'String',                        #nameBaz#
--     typeBaz  :: 'Maybe' ('TypeQ' -> 'TypeQ'),    #typeBaz#
--     typeFooX :: [('String', 'TypeQ' -> 'TypeQ')] #typeFooX#
--   }
--
-- defaultExtFoo :: <#ExtFoo ExtFoo> #defaultExtFoo#
-- defaultExtFoo = <#ExtFoo ExtFoo> {
--     <#nameBar nameBar>  = \"Bar\",
--     <#typeBar typeBar>  = 'Just' $ \\_ -> [t| () |],
--     <#nameBaz nameBaz>  = \"Baz\",
--     <#typeBaz typeBaz>  = 'Just' $ \\_ -> [t| () |],
--     <#typeFooX typeFooX> = []
--   }
--
-- extendFoo :: 'String' -- ^ Type alias name  #extendFoo#
--           -> ['Name'] -- ^ Extra type variables
--           -> 'TypeQ'  -- ^ Tag for this annotation
--           -> <#ExtFoo ExtFoo>
--           -> 'DecsQ'
-- extendFoo name vars tag exts = ...
-- @
--
-- @
-- module Foo (module <#Foo.Base Foo.Base>, module Foo) where
-- import <#Foo_Base Foo.Base>
--
-- data QZ #QZ#
--
-- <#extendFoo extendFoo> \"Foo\" [] [t|<#QZ QZ>|] $ <#defaultExtFoo defaultExtFoo> {
--   <#typeBar typeBar> = 'Nothing',  -- disable Bar
--   <#typeFooX typeFooX> =          -- add two new constructors, Quux and Zoop
--     [(\"Quux\", \\_ -> [t|'Int'|]),
--      (\"Zoop\", \\a -> [t|<#Foo' Foo'> <#QZ QZ> $a|])]
-- }
--
-- ====>
--
-- type instance <#XBar XBar> <#QZ QZ> a = 'Void'
-- type instance <#XBaz XBaz> <#QZ QZ> a = ()
-- type instance <#FooX FooX> <#QZ QZ> a = 'Either' 'Int' 'Bool'
--
-- type Foo = <#Foo' Foo'> <#QZ QZ> #Foo#
--
-- -- no pattern for <#Bar' Bar'>
--
-- pattern Baz :: <#Foo Foo> a -> <#Foo Foo> 'Int' -> <#Foo Foo> a #Baz#
-- pattern Baz x y = <#Baz' Baz'> x y ()
--
-- pattern Quux :: 'Int' -> <#Foo Foo> a #Quux#
-- pattern Quux x = <#FooX FooX> ('Left' x)
--
-- pattern Zoop :: <#Foo Foo> a -> <#Foo Foo> a #Zoop#
-- pattern Zoop x = <#FooX FooX> ('Right' x)
--
-- {-\# COMPLETE <#Baz Baz>, <#Quux Quux>, <#Zoop Zoop> #-}
-- @
--
-- @
-- data BarWith b #BarWith#
--
-- do
--   bn <- 'newName' "b"
--   let b = 'varT' bn
--   <#extendFoo extendFoo> \"Foo\" [bn] [t|<#BarWith BarWith> $b|] $
--     <#defaultExtFoo defaultExtFoo> { typeBar = 'Ann' b }
--
-- ====>
--
-- type instance <#XBar XBar> (<#BarWith BarWith> b) a = b
-- type instance <#XBaz XBaz> (<#BarWith BarWith> b) a = ()
-- type instance <#FooX FooX> (<#BarWith BarWith> b) a = 'Either' 'Int' 'Bool'
--
-- type Foo b = <#Foo' Foo'> (<#BarWith BarWith> b) #Foo2#
--
-- pattern Bar :: a -> b -> <#Foo2 Foo> b a #Bar2#
-- pattern Bar x y = <#Bar' Bar'> x y
--
-- pattern Baz :: <#Foo Foo> a -> <#Foo Foo> 'Int' -> <#Foo Foo> a #Baz2#
-- pattern Baz x y = <#Baz' Baz'> x y ()
--
-- {-\# COMPLETE <#Bar2 Bar>, <#Baz2 Baz> #-}
-- @
module Extensible
  (-- * Name manipulation
   NameAffix (.., NamePrefix, NameSuffix), applyAffix,
   -- ** Template Haskell re-exports
   newName, varT,
   -- * Generating extensible datatypes
   extensible, extensibleWith, Config (..), defaultConfig, ConAnn(..))
where

import Language.Haskell.TH as TH
import Language.Haskell.TH.Syntax
import Generics.SYB (Data, everywhere, mkT)
import Control.Monad
import Data.Functor.Identity
import Data.Void
import Data.Kind as K

-- ☹
deriving instance Lift Name
deriving instance Lift OccName
deriving instance Lift NameFlavour
deriving instance Lift ModName
deriving instance Lift NameSpace
deriving instance Lift PkgName

-- | Extra strings to add to the beginning and/or end of (the base part of)
-- 'Name's
data NameAffix =
  NameAffix {naPrefix, naSuffix :: String}
  deriving (Eq, Show, Lift)
pattern NamePrefix, NameSuffix :: String -> NameAffix
-- | Just a prefix, with an empty suffix
pattern NamePrefix pre = NameAffix {naPrefix = pre, naSuffix = ""}
-- | Just a suffix, with an empty prefix
pattern NameSuffix suf = NameAffix {naPrefix = "",  naSuffix = suf}

instance Semigroup NameAffix where
  NameAffix pre1 suf1 <> NameAffix pre2 suf2 =
    NameAffix (pre1 <> pre2) (suf2 <> suf1)
instance Monoid NameAffix where mempty = NameAffix "" ""

onNameBaseF :: Functor f => (String -> f String) -> Name -> f Name
onNameBaseF f name = addModName <$> f (nameBase name) where
  addModName b = mkName $ case nameModule name of
    Nothing -> b
    Just m  -> m ++ "." ++ b

onNameBase :: (String -> String) -> Name -> Name
onNameBase f = runIdentity . onNameBaseF (Identity . f)

-- |
-- >>> applyAffix (NameAffix "pre" "Suf") (mkName "Foo")
-- preFooSuf
-- >>> applyAffix (NameAffix "pre" "Suf") (mkName "Foo.Bar")
-- Foo.preBarSuf
applyAffix :: NameAffix -> Name -> Name
applyAffix (NameAffix pre suf) = onNameBase (\b -> pre ++ b ++ suf)


-- | Qualified a name with a module, /unless/ it is already qualified.
--
-- >>> qualifyWith "Mod" (mkName "foo")
-- Mod.foo
-- >>> qualifyWith "Mod" (mkName "OtherMod.foo")
-- OtherMod.foo
qualifyWith :: String -> Name -> Name
qualifyWith m n = case nameModule n of
  Nothing -> mkName (m ++ "." ++ nameBase n)
  Just _  -> n


-- | Configuration options for how to name the generated constructors, type
-- families, etc.
data Config = Config {
    -- | Applied to input datatype's name to get extensible type's name
    datatypeName :: NameAffix,
    -- | Applied to input constructor names to get extensible constructor names
    constructorName :: NameAffix,
    -- | Applied to type name to get constraint bundle name
    bundleName :: NameAffix,
    -- | Appled to constructor names to get the annotation type family's name
    annotationName :: NameAffix,
    -- | Applied to datatype name to get extension constructor & type family's
    -- name
    extensionName :: NameAffix,
    -- | Applied to datatype name to get extension record name
    extRecordName :: NameAffix,
    -- | Applied to constructor names to get the names of the type fields in the
    -- extension record
    extRecTypeName :: NameAffix,
    -- | Applied to constructor names to get the names of the name fields in the
    -- extension record (which are used to name the pattern synonyms)
    extRecNameName :: NameAffix,
    -- | Applied to the 'extRecordName' to get the name of the default extension
    defExtRecName :: NameAffix,
    -- | Applied to datatype name to get the name of the extension
    -- generator function
    extFunName :: NameAffix
  } deriving (Eq, Show, Lift)

-- | Default config:
--
-- @
-- Config {
--   datatypeName    = NameSuffix \"'\",
--   constructorName = NameSuffix \"'\",
--   bundleName      = NameSuffix "All",
--   annotationName  = NamePrefix \"X\",
--   extensionName   = NameSuffix \"X\",
--   extRecordName   = NamePrefix \"Ext\",
--   extRecTypeName  = NamePrefix \"type\",
--   extRecNameName  = NamePrefix \"name\",
--   defExtRecName   = NamePrefix \"default\",
--   extFunName      = NamePrefix \"extend\"
-- }
-- @
defaultConfig :: Config
defaultConfig = Config {
    datatypeName    = NameSuffix "'",
    constructorName = NameSuffix "'",
    bundleName      = NameSuffix "All",
    annotationName  = NamePrefix "X",
    extensionName   = NameSuffix "X",
    extRecordName   = NamePrefix "Ext",
    extRecTypeName  = NamePrefix "type",
    extRecNameName  = NamePrefix "name",
    defExtRecName   = NamePrefix "default",
    extFunName      = NamePrefix "extend"
  }


-- | An annotation for a constructor. @t@ is @'TypeQ' -> ... -> 'TypeQ'@ with
-- one argument for each type variable in the original datatype declaration.
--
-- * 'Ann': the annotation is the given type
-- * 'NoAnn': no annotation (filled in with @()@ automatically by the pattern
--   synonym)
-- * 'Disabled': constructor disabled (annotation type is 'Void' and no pattern
--   synonym generated)
data ConAnn t = Ann t | NoAnn | Disabled


-- | A \"simple\" constructor (non-record, non-GADT)
data SimpleCon = SimpleCon {
    scName   :: Name,
    scFields :: [BangType]
  } deriving (Eq, Show, Data)

-- | A \"simple\" datatype (no context, no kind signature, no deriving)
data SimpleData = SimpleData {
    sdName   :: Name,
    sdVars   :: [TyVarBndr],
    sdCons   :: [SimpleCon],
    sdDerivs :: [SimpleDeriv]
  } deriving (Eq, Show, Data)

-- 'SBlank' and 'SStock' have the same effect but the first will trigger
-- @-Wmissing-deriving-strategies@ if it is enabled and the second requires
-- the @DerivingStrategies@ extension
data SimpleStrategy = SBlank | SStock | SAnyclass deriving (Eq, Show, Data)

-- | A \"simple\" deriving clause—either @stock@ or @anyclass@ strategy
data SimpleDeriv =
  SimpleDeriv {
    sdStrat   :: SimpleStrategy,
    dsContext :: Cxt
  } deriving (Eq, Show, Data)

-- | Extract a 'SimpleData' from a 'Dec', if it is a datatype with the given
-- restrictions.
simpleData :: Dec -> Q SimpleData
simpleData (DataD ctx name tvs kind cons derivs)
  | not $ null ctx    = fail "data contexts unsupported"
  | Just _ <- kind    = fail "kind signatures unsupported"
  | otherwise =
      SimpleData name tvs
        <$> traverse simpleCon cons
        <*> traverse simpleDeriv derivs
simpleData _ = fail "not a datatype"

-- | Extract a 'SimpleCon' from a 'Con', if it is the 'NormalC' case.
simpleCon :: Con -> Q SimpleCon
simpleCon (NormalC name fields) = pure $ SimpleCon name fields
simpleCon _ = fail "only simple constructors supported for now"

simpleDeriv :: DerivClause -> Q SimpleDeriv
simpleDeriv (DerivClause strat prds) =
  SimpleDeriv <$> simpleStrat strat <*> pure prds
 where
  simpleStrat Nothing                 = pure SBlank
  simpleStrat (Just StockStrategy)    = pure SStock
  simpleStrat (Just AnyclassStrategy) = pure SAnyclass
  simpleStrat (Just NewtypeStrategy)  = fail "newtype deriving unsupported"
  simpleStrat (Just (ViaStrategy _))  = fail "deriving via unsupported"

-- | As 'extensibleWith', using 'defaultConfig'.
extensible :: DecsQ -> DecsQ
extensible = extensibleWith defaultConfig

-- | Generate an extensible datatype using the given 'Config' for creating
-- names. See <#maindoc the module documentation> for more detail on what this
-- function spits out.
extensibleWith :: Config -> DecsQ -> DecsQ
extensibleWith conf ds = do
  ds'  <- traverse simpleData =<< ds
  home <- loc_module <$> location
  makeExtensible conf home ds'

tyvarName :: TyVarBndr -> Name
tyvarName (PlainTV  x)   = x
tyvarName (KindedTV x _) = x

makeExtensible :: Config
               -> String -- ^ module where @extensible{With}@ was called
               -> [SimpleData] -> DecsQ
makeExtensible conf home datas =
  let nameMap = [(name, applyAffix (datatypeName conf) name)
                  | SimpleData {sdName = name} <- datas]
  in concat <$> mapM (makeExtensible1 conf home nameMap) datas

makeExtensible1 :: Config
                -> String -- ^ module where @extensible{With}@ was called
                -> [(Name, Name)] -- ^ mapping @(old, new)@ for datatype names
                -> SimpleData -> DecsQ
makeExtensible1 conf home nameMap (SimpleData name tvs cs derivs) = do
  let name' = applyAffix (datatypeName conf) name
  ext <- newName "ext"
  let tvs' = PlainTV ext : tvs
  cs' <- traverse (extendCon conf nameMap ext tvs) cs
  let cx = extensionCon conf name ext tvs
  efs <- traverse (extendFam conf tvs) cs
  efx <- extensionFam conf name tvs
  bnd <- constraintBundle conf name ext tvs cs
  insts <- fmap concat $
    traverse (makeInstances conf name' (map fst nameMap) ext tvs) derivs
  (rname, fcnames, fname, rec) <- extRecord conf name tvs cs
  (_dname, defRec) <- extRecDefault conf rname fcnames fname
  (_ename, extFun) <- makeExtender conf home name rname tvs cs
  return $
    DataD [] name' tvs' Nothing (cs' ++ [cx]) [] :
    efs ++ [efx, bnd] ++ insts ++ [rec] ++ defRec ++ extFun

nonstrict :: Bang
nonstrict = Bang NoSourceUnpackedness NoSourceStrictness

strict :: Bang
strict = Bang NoSourceUnpackedness SourceStrict

-- | @appExtTvs t ext tvs@ applies @t@ to @ext@ and then to all of @tvs@.
appExtTvs :: TH.Type -> Name -> [TyVarBndr] -> TH.Type
appExtTvs t ext tvs = foldl AppT t $ fmap VarT $ ext : fmap tyvarName tvs

-- | Generate an extended constructor by renaming it and replacing recursive
-- occrences of the datatype.
extendCon :: Config
          -> [(Name, Name)] -- ^ original & new datatype names
          -> Name -- ^ new type variable name
          -> [TyVarBndr] -- ^ original type variables
          -> SimpleCon -> ConQ
extendCon conf nameMap ext tvs (SimpleCon name fields) = do
  let name' = applyAffix (constructorName conf) name
      xname = applyAffix (annotationName conf) name
      fields' = map (extendRec nameMap ext) fields
  pure $ NormalC name' $
    fields' ++ [(strict, appExtTvs (ConT xname) ext tvs)]

-- | Replaces recursive occurences of the datatype with the new one.
extendRec :: [(Name, Name)] -- ^ original & new datatype names
          -> Name -- ^ new type variable name
          -> BangType -> BangType
extendRec nameMap ext = everywhere $ mkT go where
  go (ConT k) | Just new <- lookup k nameMap = ConT new `AppT` VarT ext
  go t = t

extensionCon :: Config -> Name -> Name -> [TyVarBndr] -> Con
extensionCon conf name ext tvs =
  let namex = applyAffix (extensionName conf) name in
  NormalC namex [(strict, appExtTvs (ConT namex) ext tvs)]

extendFam :: Config -> [TyVarBndr] -> SimpleCon -> DecQ
extendFam conf tvs (SimpleCon name _) =
  extendFam' (applyAffix (annotationName conf) name) tvs

extensionFam :: Config -> Name -> [TyVarBndr] -> DecQ
extensionFam conf name tvs =
  extendFam' (applyAffix (extensionName conf) name) tvs

constraintBundle :: Config
                 -> Name -- ^ datatype name
                 -> Name -- ^ extension type variable name
                 -> [TyVarBndr] -> [SimpleCon] -> DecQ
constraintBundle conf name ext tvs cs = do
  c <- newName "c"
  ckind <- [t|K.Type -> Constraint|]
  let cnames = map scName cs
      bname  = applyAffix (bundleName conf) name
      tvs'   = kindedTV c ckind : plainTV ext : tvs
      con1 n = varT c `appT`
               foldl appT (conT n) (varT ext : map (varT . tyvarName) tvs)
      tupled ts = foldl appT (tupleT (length ts)) ts
  tySynD bname tvs' $ tupled $ map con1 $
    map (applyAffix $ annotationName conf) cnames ++
    [applyAffix (extensionName conf) name]

makeInstances :: Config
              -> Name   -- ^ name of the __output__ datatype
              -> [Name] -- ^ names of all datatypes in this group
              -> Name   -- ^ extension type variable name
              -> [TyVarBndr]
              -> SimpleDeriv
              -> DecsQ
makeInstances conf name names ext tvs (SimpleDeriv strat prds) =
  pure $ map make1 prds
 where
  make1 prd = StandaloneDerivD strat'
    (map tvPred tvs ++ map allPred names)
    (prd `AppT` appExtTvs (ConT name) ext tvs)
   where
    tvPred = AppT prd . VarT . tyvarName
    allPred name' = appExtTvs (ConT bname `AppT` prd) ext tvs
      where bname = applyAffix (bundleName conf) name'
    strat' = case strat of
      SBlank    -> Nothing
      SStock    -> Just StockStrategy
      SAnyclass -> Just AnyclassStrategy

extendFam' :: Name -> [TyVarBndr] -> DecQ
extendFam' name tvs = do
  ext <- newName "ext"
  pure $ OpenTypeFamilyD $ TypeFamilyHead name (PlainTV ext : tvs) NoSig Nothing

-- | Generates the @XExts@ record, whose values contain descriptions of the
-- extensions applied to @X@.
--
-- Returns, in order:
--
-- * record name
-- * constructor annotation field names
--   (type field, name field, constructor name)
-- * extension constructor field name
-- * record declaration to splice
extRecord :: Config -> Name -> [TyVarBndr] -> [SimpleCon]
          -> Q (Name, [(Name, Name, String)], Name, Dec)
extRecord conf cname tvs cs = do
  let rname = applyAffix (extRecordName conf) cname
      conann_  t = [t| ConAnn $t |]
      lblList_ t = [t| [(String, $t)] |]
  tfields  <- traverse (extRecTypeField conann_ conf tvs . scName) cs
  nfields  <- traverse (extRecNameField conf . scName) cs
  extField <- extRecTypeField lblList_ conf tvs
                (applyAffix (extensionName conf) cname)
  pure (rname,
        zip3 (map fieldName tfields)
             (map fieldName nfields)
             (map (nameBase . scName) cs),
        fieldName extField,
        DataD [] rname [] Nothing
          [RecC rname (tfields ++ nfields ++ [extField])] [])
 where
  fieldName (n, _, _) = n

extRecTypeField :: (TypeQ -> TypeQ)
                -> Config -> [TyVarBndr] -> Name -> VarBangTypeQ
extRecTypeField f conf tvs name = do
  let fname = applyAffix (extRecTypeName conf) name
  ty <- f (mkTy tvs)
  pure (fname, nonstrict, ty)
 where
  mkTy []     = [t|TypeQ|]
  mkTy (_:xs) = [t|TypeQ -> $(mkTy xs)|]

extRecNameField :: Config -> Name -> VarBangTypeQ
extRecNameField conf name = do
  let fname = applyAffix (extRecNameName conf) name
  ty <- [t|String|]
  pure (fname, nonstrict, ty)

extRecDefault :: Config
              -> Name -- ^ record name
              -> [(Name, Name, String)]
                  -- ^ type field, name field, and constructor name for each
                  -- constructor
              -> Name -- ^ field name for extension
              -> Q (Name, [Dec])
extRecDefault conf rname fcnames fname = do
  let mkField (t, n, c) = [fieldExp t [|NoAnn|], fieldExp n (stringE c)]
      fields = concatMap mkField fcnames
      xfield = fieldExp fname [| [] |]
      dname = applyAffix (defExtRecName conf) rname
  defn <- valD (varP dname) (normalB (recConE rname (fields ++ [xfield]))) []
  pure (dname, [SigD dname (ConT rname), defn])

-- | Generate the @extendX@ function, which is used to generate extended
-- versions of @X@
makeExtender :: Config
             -> String -- ^ module where @extensible@ was called
             -> Name   -- ^ datatype name
             -> Name   -- ^ extension record name
             -> [TyVarBndr] -> [SimpleCon] -> Q (Name, [Dec])
makeExtender conf home name' rname' tvs cs = do
  let name  = qualifyWith home name'
      rname = qualifyWith home rname'
      ename = applyAffix (extFunName conf) name'
  sig  <- sigD ename [t|String -> [Name] -> TypeQ -> $(conT rname) -> DecsQ|]
  syn  <- newName "syn"
  vars <- newName "vars"
  tag  <- newName "tag"
  exts <- newName "exts"
  defn <- [|sequence $ concat $(listE $
              map (decsForCon conf home exts tag tvs) cs ++
              [decsForExt conf home exts tag tvs name,
               makeTySyn conf home name syn vars tag,
               completePrag conf exts cs name])|]
  let val = FunD ename
        [Clause (map VarP [syn, vars, tag, exts]) (NormalB defn) []]
  pure (ename, [sig, val])

-- | Generates a type synonym for an extensible datatype applied to a specific
-- extension type, like @type Foo = Foo' Ext1@.
makeTySyn :: Config
          -> String -- ^ module where @extensible@ was called
          -> Name   -- ^ datatype name
          -> Name   -- ^ variable containing synonym's name
          -> Name   -- ^ variable containing extension's extra type arguments
          -> Name   -- ^ variable containing tag type
          -> ExpQ
makeTySyn conf home name syn vars tag =
  let tyname = qualifyWith home $ applyAffix (datatypeName conf) name in
  [|[tySynD (mkName $(varE syn))
            (map plainTV $(varE vars))
            (appT (conT tyname) $(varE tag))]|]

-- | Generates the type instance and pattern synonym (if any) for a constructor.
decsForCon :: Config
           -> String -- ^ module where @extensible@ was called
           -> Name -- ^ name of the bound @exts@ variable in @extendX@
           -> Name -- ^ name of the bound @tag@ variable in @extendX@
           -> [TyVarBndr] -> SimpleCon -> ExpQ
decsForCon conf home extsName tagName tvs (SimpleCon name fields) = do
  tvs' <- replicateM (length tvs) (newName "a")
  ann  <- newName "ann"
  args <- replicateM (length fields) (newName "x")
  let tyfam = qualifyWith home $ applyAffix (annotationName conf) name
      name' = qualifyWith home $ applyAffix (constructorName conf) name
      typeC = varE $ qualifyWith home $ applyAffix (extRecTypeName conf) name
      nameC = varE $ qualifyWith home $ applyAffix (extRecNameName conf) name
      exts  = varE extsName; tag = varE tagName
  [|let
#if MIN_VERSION_template_haskell(2,15,0)
        mkTf rhs = tySynInstD $
          tySynEqn Nothing
            (foldl appT (conT tyfam) $ $tag : map varT tvs')
            rhs
#else
        mkTf rhs = tySynInstD tyfam $ tySynEqn ($tag : map varT tvs') rhs
#endif
        annType = $typeC $exts; patName = mkName $ $nameC $exts
        mkPatSyn args' rhs = patSynD patName (prefixPatSyn args') implBidir rhs
    in
    case annType of
      Ann ty ->
        [mkTf $(foldl appE [|ty|] [[|varT a|] | a <- tvs']),
         mkPatSyn (args ++ [ann]) (conP name' (map varP (args ++ [ann])))]
      NoAnn ->
        [mkTf (tupleT 0),
         mkPatSyn args (conP name' (map varP args ++ [conP $(lift '()) []]))]
      Disabled ->
        [mkTf (conT $(lift ''Void))]
   |]

-- | Generates the type instance and pattern synonym(s) for the extension.
decsForExt :: Config
           -> String -- ^ module where @extensible@ was called
           -> Name -- ^ name of the bound @exts@ variable in @extendX@
           -> Name -- ^ name of the bound @tag@ variable in @extendX@
           -> [TyVarBndr] -> Name -> ExpQ
decsForExt conf home extsName tagName tvs name = do
  args <- replicateM (length tvs) (newName "a")
  let cname' = applyAffix (extensionName conf) name
      cname  = qualifyWith home cname'
      typeC = varE $ applyAffix (extRecTypeName conf) cname'
      tyfam = applyAffix (extensionName conf) name
      exts  = varE extsName; tag = varE tagName
  [|let typs = $typeC $exts
        tySynRhs = case typs of
          [] -> conT $(lift ''Void)
          ts -> foldr1 mkEither $ map (appArgs . snd) ts
          where mkEither t u = conT $(lift ''Either) `appT` t `appT` u
                appArgs t = $(appsE $ [|t|] : map (\x -> [|varT x|]) args)
#if MIN_VERSION_template_haskell(2,15,0)
        tySyn = tySynInstD $ tySynEqn Nothing
          (foldl appT (conT tyfam) ($tag : map varT args))
          tySynRhs
#else
        tySyn = tySynInstD tyfam $
          tySynEqn ($tag : map varT args) tySynRhs
#endif
        mkPatSyn mkRhs (patName, _) = do
          x <- newName "x"
          patSynD (mkName patName) (prefixPatSyn [x]) implBidir
            (conP cname [mkRhs (varP x)])
    in
    tySyn : zipWith mkPatSyn (makeEithers (length typs)) typs|]

-- | Generates an expression producing a @COMPLETE@ pragma.
completePrag :: Config
             -> Name -- ^ name of @exts@ argument
             -> [SimpleCon]
             -> Name -- ^ name of datatype
             -> ExpQ
completePrag conf extsName cs name =
  let exts = varE extsName
      mkCie cie (SimpleCon cname _) =
        let nameC = varE $ applyAffix (extRecNameName conf) cname
            typeC = varE $ applyAffix (extRecTypeName conf) cname
        in
        [|$cie (mkName ($nameC $exts)) ($typeC $exts)|]
      typeE = varE $ applyAffix (extRecTypeName <> extensionName $ conf) name
  in
  [|let conIfEnabled _ Disabled = []
        conIfEnabled n _        = [n]
        allExts = map $ mkName . fst
    in
    [pragCompleteD
      (concat $(listE $ map (mkCie [|conIfEnabled|]) cs) ++
       allExts ($typeE $exts))
      Nothing]
   |]

-- | Generates a list of functions which wrap patterns in successive branches of
-- right-nested 'Either's. For example, @makeEithers 4@ produces:
--
-- @
-- [\p -> [p|Left $p|],
--  \p -> [p|Right (Left $p)|],
--  \p -> [p|Right (Right (Left $p))|],
--  \p -> [p|Right (Right (Right $p))|]]
-- @
makeEithers :: Int -> [PatQ -> PatQ]
makeEithers = addEithers' id where
  addEithers' _ 0 = []
  addEithers' f 1 = [f]
  addEithers' f n =
    (\p -> f [p|Left $p|]) :
    addEithers' (\p -> [p|Right $(f p)|]) (n - 1)