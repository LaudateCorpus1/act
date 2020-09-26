{-
 -
 - coq backend for act
 -
 - unsupported features:
 - + bytestrings
 - + external storage
 - + specifications for multiple contracts
 -
 -}

{-# Language OverloadedStrings #-}
{-# LANGUAGE GADTs #-}

module Coq where

import qualified Data.Map.Strict    as M
import qualified Data.List.NonEmpty as NE
import qualified Data.Text          as T
import Data.Either (rights)
import Data.Maybe (mapMaybe, listToMaybe)

import EVM.ABI
import EVM.Solidity (SlotType(..))
import Syntax
import RefinedAst

type Store = M.Map Id (M.Map Id SlotType)

-- | string module name
strName :: T.Text
strName  = "Str"

-- | base state name
baseName :: T.Text
baseName = "BASE"

header :: T.Text
header =
  "(* --- GENERATED BY ACT --- *)\n\n\
  \Require Import Coq.ZArith.ZArith.\n\
  \Require Import ActLib.ActLib.\n\
  \Require Coq.Strings.String.\n\n\
  \Module " <> strName <> " := Coq.Strings.String.\n\
  \Open Scope Z_scope.\n\n"

-- | produce a coq representation of a specification
coq :: Store -> [Claim] -> T.Text
coq store claims =

  case mapMaybe isConstructor claims of
    [c] -> header
      <> layout store <> "\n\n"
      <> T.intercalate "\n\n" (mapMaybe (claim store) claims) <> "\n\n"
      <> base store c <> "\n\n"
      <> reachable claims
    _ -> error "multiple constructors not supported"

  where

  isConstructor (B b) | (_creation b) && (_mode b == Pass) = Just b
  isConstructor _ = Nothing

  layout store' = "Record State : Set := state\n" <> "{ "
    <> T.intercalate ("\n" <> "; ") (map decl pairs)
    <> "\n" <> "}." where
    pairs = M.toList (headval store')

  decl (n, s) = (T.pack n) <> " : " <> slotType s

-- | definition of the base state
base :: Store -> Behaviour -> T.Text
base store constructor =
  "Definition " <> baseName <> " :=\n"
    <> stateval store (\_ t -> defaultValue t) (_stateUpdates constructor)
    <> "\n."

-- | inductive definition of reachable states
reachable :: [Claim] -> T.Text
reachable claims =
  "Inductive reachable : State -> Prop :=\n"
    <> "| base : reachable BASE\n"
    <> T.intercalate "\n" (mapMaybe reachableStep claims)
    <> "\n."
  where
    reachableStep (B b) | _mode b == Pass && not (_creation b) = Just $
      "| " <> T.pack (_name b)
      <> "_step : forall (s : State) "
      <> interface (_interface b)
      <> ", reachable s -> reachable ("
      <> T.pack (_name b)
      <> " s " <> arguments (_interface b) <> ")"
    reachableStep _ = Nothing
    arguments (Interface _ decls) =
      T.intercalate " " (map (\(Decl _ name) -> T.pack name) decls)

-- | definition of a contract function
-- ignores OOG and Fail claims
-- ignores constructors (claims that include creation)
claim :: Store -> Claim -> Maybe T.Text
claim store (B b@(Behaviour n m c _ i _ _ _ _)) =

  case (m, c) of
    (Pass, False) -> Just $ "Definition "
      <> T.pack n
      <> " (s : State) "
      <> interface i
      <> " :=\n"
      <> body store b
    (_, _) -> Nothing

  where

  body store' (Behaviour _ _ _ _ _ preconditions _ updates _) =
    "match "
      <> coqexp preconditions
      <> " with\n| true => "
      <> stateval store' (\n' _ -> T.pack n' <> " s") updates
      <> "\n| false => s\nend."

claim _ _ = Nothing

-- | produce a state value from a list of storage updates
-- 'handler' defines what to do in cases where a given name isn't updated
stateval
  :: Store
  -> (Id -> SlotType -> T.Text)
  -> [Either StorageLocation StorageUpdate]
  -> T.Text
stateval store handler updates =

  "state " <> T.intercalate " "
    (map (valuefor (rights updates)) (M.toList (headval store)))

  where

  valuefor :: [StorageUpdate] -> (Id, SlotType) -> T.Text
  valuefor updates' (name, t) =
    case listToMaybe (filter (f name) updates') of
      Nothing -> parens $ handler name t
      Just (IntUpdate (DirectInt _ _) e) -> parens $ coqexp e
      Just (IntUpdate (MappedInt _ name' args) e) -> lambda (NE.toList args) 0 e name'
      Just (BoolUpdate (DirectBool _ _) e)  -> parens $ coqexp e
      Just (BoolUpdate (MappedBool _ name' args) e) -> lambda (NE.toList args) 0 e name'
      Just (BytesUpdate _ _) -> error "bytestrings not supported"

  -- filter by name
  f n (IntUpdate (DirectInt _ n') _)
    | n == n' = True
  f n (IntUpdate (MappedInt _ n' _) _)
    | n == n' = True
  f n (BoolUpdate (DirectBool _ n') _)
    | n == n' = True
  f n (BoolUpdate (MappedBool _ n' _) _)
    | n == n' = True
  f _ _ = False

  -- represent mapping update with anonymous function
  lambda :: [ReturnExp] -> Int -> Exp a -> Id -> T.Text
  lambda [] _ e _ = parens $ coqexp e
  lambda (x:xs) n e m = let name = "debruijn" <> T.pack (show n) in parens $ "fun "
    <> name
    <> " => if "
    <> name <> eqsym x <> retexp x <> " then " <> lambda xs (n + 1) e m <> " else "
    <> T.pack m <> " s " <> lambdaArgs n

  lambdaArgs n = T.intercalate " " $ map (\x -> "debruijn" <> T.pack (show x)) [0..n]

  eqsym (ExpInt _) = " =? "
  eqsym (ExpBool _) = " =?? "
  eqsym (ExpBytes _) = error "bytestrings not supported"

-- | produce a block of declarations from an interface
interface :: Interface -> T.Text
interface (Interface _ decls) =
  T.intercalate " " (map decl decls) where
  decl (Decl t name) = parens $ T.pack name <> " : " <> abiType t

-- | coq syntax for a slot type
slotType :: SlotType -> T.Text
slotType (StorageMapping xs t) =
  T.intercalate " -> " (map abiType (NE.toList xs ++ [t]))
slotType (StorageValue abitype) = abiType abitype

-- | coq syntax for an abi type
abiType :: AbiType -> T.Text
abiType (AbiUIntType _) = "Z"
abiType (AbiIntType _) = "Z"
abiType AbiAddressType = "address"
abiType AbiStringType = strName <> ".string"
abiType a = error $ show a

-- | default value for a given type
-- this is used in cases where a value is not set in the constructor
defaultValue :: SlotType -> T.Text
defaultValue t =

  case t of
    (StorageMapping xs t') -> "fun "
      <> T.intercalate " " (replicate (length (NE.toList xs)) "_")
      <> " => "
      <> abiVal t'
    (StorageValue t') -> abiVal t'

  where

  abiVal (AbiUIntType _) = "0"
  abiVal (AbiIntType _) = "0"
  abiVal AbiAddressType = "0"
  abiVal AbiStringType = strName <> ".EmptyString"
  abiVal _ = error "TODO: missing default values"

-- | coq syntax for an expression
coqexp :: Exp a -> T.Text

-- booleans
coqexp (LitBool True)  = "true"
coqexp (LitBool False) = "false"
coqexp (BoolVar name) = T.pack name
coqexp (And e1 e2)  = parens $ "andb "   <> coqexp e1 <> " " <> coqexp e2
coqexp (Or e1 e2)   = parens $ "orb"     <> coqexp e1 <> " " <> coqexp e2
coqexp (Impl e1 e2) = parens $ "implb"   <> coqexp e1 <> " " <> coqexp e2
coqexp (Eq e1 e2)   = parens $ coqexp e1  <> " =? " <> coqexp e2
coqexp (NEq e1 e2)  = parens $ "negb " <> parens (coqexp e1  <> " =? " <> coqexp e2)
coqexp (Neg e)      = parens $ "negb " <> coqexp e
coqexp (LE e1 e2)   = parens $ coqexp e1 <> " <? "  <> coqexp e2
coqexp (LEQ e1 e2)  = parens $ coqexp e1 <> " <=? " <> coqexp e2
coqexp (GE e1 e2)   = parens $ coqexp e2 <> " <? "  <> coqexp e1
coqexp (GEQ e1 e2)  = parens $ coqexp e2 <> " <?= " <> coqexp e1
coqexp (TEntry (DirectBool _ name)) = parens $ T.pack name <> " s"
coqexp (TEntry (MappedBool _ name args)) = parens $ T.pack name <> " s " <> coqargs args

-- integers
coqexp (LitInt i) = T.pack $ show i
coqexp (IntVar name) = T.pack name
coqexp (Add e1 e2) = parens $ coqexp e1 <> " + " <> coqexp e2
coqexp (Sub e1 e2) = parens $ coqexp e1 <> " - " <> coqexp e2
coqexp (Mul e1 e2) = parens $ coqexp e1 <> " * " <> coqexp e2
coqexp (Div e1 e2) = parens $ coqexp e1 <> " / " <> coqexp e2
coqexp (Mod e1 e2) = parens $ "Z.modulo " <> coqexp e1 <> coqexp e2
coqexp (Exp e1 e2) = parens $ coqexp e1 <> " ^ " <> coqexp e2
coqexp (IntMin n)  = parens $ "INT_MIN "  <> T.pack (show n)
coqexp (IntMax n)  = parens $ "INT_MAX "  <> T.pack (show n)
coqexp (UIntMin n) = parens $ "UINT_MIN " <> T.pack (show n)
coqexp (UIntMax n) = parens $ "UINT_MAX " <> T.pack (show n)
coqexp (TEntry (DirectInt _ name)) = parens $ T.pack name <> " s"
coqexp (TEntry (MappedInt _ name args)) = parens $ T.pack name <> " s " <> coqargs args

-- polymorphic
coqexp (ITE b e1 e2) = parens $ "if "
  <> coqexp b
  <> " then "
  <> coqexp e1
  <> " else "
  <> coqexp e2

-- unsupported
coqexp (IntEnv e) = error $ show e <> ": environment values not yet supported"
coqexp (Cat _ _) = error "bytestrings not supported"
coqexp (Slice _ _ _) = error "bytestrings not supported"
coqexp (ByVar _) = error "bytestrings not supported"
coqexp (ByStr _) = error "bytestrings not supported"
coqexp (ByLit _) = error "bytestrings not supported"
coqexp (ByEnv _) = error "bytestrings not supported"
coqexp (TEntry (DirectBytes _ _)) = error "bytestrings not supported"
coqexp (TEntry (MappedBytes _ _ _)) = error "bytestrings not supported"
coqexp (NewAddr _ _) = error "newaddr not supported"

-- | coq syntax for a return expression
retexp :: ReturnExp -> T.Text
retexp (ExpInt e) = coqexp e
retexp (ExpBool e) = coqexp e
retexp (ExpBytes _) = error "bytestrings not supported"

-- | coq syntax for a list of arguments
coqargs :: NE.NonEmpty ReturnExp -> T.Text
coqargs (e NE.:| es) =
  retexp e <> " " <> T.intercalate " " (map retexp es) where

-- | wrap text in parentheses
parens :: T.Text -> T.Text
parens s = "(" <> s <> ")"

headval :: M.Map k a -> a
headval = snd . head . M.toList