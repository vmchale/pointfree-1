{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE PatternGuards     #-}
module Plugin.Pl.Transform (
    transform,
  ) where

import           Control.Monad.Trans.State
import           Data.Graph                (flattenSCC, flattenSCCs,
                                            stronglyConnComp)
import qualified Data.Map                  as M
import           Data.Maybe
import           Plugin.Pl.Common

occursP :: String -> Pattern -> Bool
occursP v (PVar v')      = v == v'
occursP v (PTuple p1 p2) = v `occursP` p1 || v `occursP` p2
occursP v (PCons  p1 p2) = v `occursP` p1 || v `occursP` p2

freeIn :: String -> Expr -> Int
freeIn v (Var _ v') = fromEnum $ v == v'
freeIn v (Lambda pat e) = if v `occursP` pat then 0 else freeIn v e
freeIn v (App e1 e2) = freeIn v e1 + freeIn v e2
freeIn v (Let ds e') = if v `elem` map declName ds then 0
  else freeIn v e' + sum [freeIn v e | Define _ e <- ds]

isFreeIn :: String -> Expr -> Bool
isFreeIn v e = freeIn v e > 0

tuple :: [Expr] -> Expr
tuple  = foldr1 (\x y -> Var Inf "," `App` x `App` y)

tupleP :: [String] -> Pattern
tupleP vs = foldr1 PTuple $ PVar `map` vs

dependsOn :: [Decl] -> Decl -> [Decl]
dependsOn ds d = [d' | d' <- ds, declName d' `isFreeIn` declExpr d]

unLet :: Expr -> Expr
unLet (App e1 e2) = App (unLet e1) (unLet e2)
unLet (Let [] e) = unLet e
unLet (Let ds e) = unLet $
  Lambda (tupleP $ declName `map` dsYes) (Let dsNo e) `App`
    (fix' `App` Lambda (tupleP $ declName `map` dsYes)
                        (tuple  $ declExpr `map` dsYes))
    where
  comps = stronglyConnComp [(d',d',dependsOn ds d') | d' <- ds]
  dsYes = flattenSCC $ head comps
  dsNo = flattenSCCs $ tail comps

unLet (Lambda v e) = Lambda v (unLet e)
unLet (Var f x) = Var f x

type Env = M.Map String String

-- It's a pity we still need that for the pointless transformation.
-- Otherwise a newly created id/const/... could be bound by a lambda
-- e.g. transform' (\id x -> x) ==> transform' (\id -> id) ==> id
alphaRename :: Expr -> Expr
alphaRename e = alpha e `evalState` M.empty where
  alpha :: Expr -> State Env Expr
  alpha (Var f v)     = Var f . fromMaybe v . M.lookup v <$> get
  alpha (App e1 e2)   = liftM2 App (alpha e1) (alpha e2)
  alpha (Let _ _)     = assert False bt
  alpha (Lambda v e') = inEnv $ liftM2 Lambda (alphaPat v) (alpha e')

  -- act like a reader monad
  inEnv :: State s a -> State s a
  inEnv f = gets $ evalState f

  alphaPat (PVar v) = do
    fm <- get
    let v' = "$" ++ show (M.size fm)
    put $ M.insert v v' fm
    return $ PVar v'
  alphaPat (PTuple p1 p2) = liftM2 PTuple (alphaPat p1) (alphaPat p2)
  alphaPat (PCons p1 p2) = liftM2 PCons (alphaPat p1) (alphaPat p2)


transform :: Expr -> Expr
transform = transform' . alphaRename . unLet

-- Infinite generator of variable names.
varNames :: [String]
varNames = flip replicateM usableChars =<< [1..]
  where
    usableChars = ['a'..'z']

-- First variable name not already in use
fresh :: [String] -> String
fresh variables = head . filter (not . flip elem variables) $ varNames

names :: Expr -> [String]
names (Var _ str)     = [str]
-- Lambda pattern names are rewritten to be meaningless/unwritable, so we don't
-- need to include them here. Variables from lambdas used in expressions are
-- also rewritten, but there's no reason to special-case it unless it's provably
-- poor-performing to scan over the result in `fresh`, which I doubt it is.
names (Lambda _ exp') = names exp'
names (App exp1 exp2) = names exp1 ++ names exp2
names (Let dlcs exp') = (dnames =<< dlcs) ++ names exp'
  where
    dnames (Define nm exp'') = nm : names exp''

transform' :: Expr -> Expr
transform' exp' = go exp'
  where
    -- Explicit sharing for readability
    vars = names exp'

    go Let {} =
      assert False bt
    go (Var f v) =
      Var f v
    go (App e1 e2) =
      App (go e1) (go e2)
    go (Lambda (PTuple p1 p2) e) =
      go $
        Lambda (PVar var) $ (Lambda p1 . Lambda p2 $ e) `App` f `App` s
      where
        var   = fresh vars
        f     = Var Pref "fst" `App` Var Pref var
        s     = Var Pref "snd" `App` Var Pref var
    go (Lambda (PCons p1 p2) e) =
      go $
        Lambda (PVar var) $ (Lambda p1 . Lambda p2 $ e) `App` f `App` s
      where
        var = fresh vars
        f   = Var Pref "head" `App` Var Pref var
        s   = Var Pref "tail" `App` Var Pref var
    go (Lambda (PVar v) e) =
      go $ getRidOfV e
      where
        getRidOfV (Var f v') | v == v'   = id'
                             | otherwise = const' `App` Var f v'
        getRidOfV l@(Lambda pat _) =
          assert (not $ v `occursP` pat) $ getRidOfV $ go l
        getRidOfV Let {} = assert False bt
        getRidOfV e'@(App e1 e2)
          | fr1 && fr2 = scomb `App` getRidOfV e1 `App` getRidOfV e2
          | fr1 = flip' `App` getRidOfV e1 `App` e2
          | Var _ v' <- e2, v' == v = e1
          | fr2 = comp `App` e1 `App` getRidOfV e2
          | otherwise = const' `App` e'
          where
            fr1 = v `isFreeIn` e1
            fr2 = v `isFreeIn` e2
