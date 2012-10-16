{-# LANGUAGE PatternGuards #-}

module Core.CaseTree(CaseDef(..), SC(..), CaseAlt(..), Phase(..), CaseTree,
                     simpleCase, small, namesUsed, findCalls, findUsedArgs) where

import Core.TT

import Control.Monad.State
import Data.Maybe
import Data.List hiding (partition)
import Debug.Trace

data CaseDef = CaseDef [Name] SC [Term]
    deriving Show

data SC = Case Name [CaseAlt] -- invariant: lowest tags first
        | ProjCase Term [CaseAlt] -- special case for projections
        | STerm Term
        | UnmatchedCase String -- error message
        | ImpossibleCase -- already checked to be impossible
    deriving (Eq, Ord)
{-! 
deriving instance Binary SC 
!-}

data CaseAlt = ConCase Name Int [Name] SC
             | ConstCase Const         SC
             | DefaultCase             SC
    deriving (Show, Eq, Ord)
{-! 
deriving instance Binary CaseAlt 
!-}

instance Show SC where
    show sc = show' 1 sc
      where
        show' i (Case n alts) = "case " ++ show n ++ " of\n" ++ indent i ++ 
                                    showSep ("\n" ++ indent i) (map (showA i) alts)
        show' i (ProjCase tm alts) = "case " ++ show tm ++ " of " ++
                                      showSep ("\n" ++ indent i) (map (showA i) alts)
        show' i (STerm tm) = show tm
        show' i (UnmatchedCase str) = "error " ++ show str
        show' i ImpossibleCase = "impossible"

        indent i = concat $ take i (repeat "    ")

        showA i (ConCase n t args sc) 
           = show n ++ "(" ++ showSep (", ") (map show args) ++ ") => "
                ++ show' (i+1) sc
        showA i (ConstCase t sc) 
           = show t ++ " => " ++ show' (i+1) sc
        showA i (DefaultCase sc) 
           = "_ => " ++ show' (i+1) sc
              

type CaseTree = SC
type Clause   = ([Pat], (Term, Term))
type CS = ([Term], Int)

instance TermSize SC where
    termsize (Case n as) = termsize as
    termsize (STerm t) = termsize t
    termsize _ = 1

instance TermSize CaseAlt where
    termsize (ConCase _ _ _ s) = termsize s
    termsize (ConstCase _ s) = termsize s
    termsize (DefaultCase s) = termsize s

-- simple terms can be inlined trivially - good for primitives in particular
small :: SC -> Bool
small t = termsize t < 150

namesUsed :: SC -> [Name]
namesUsed sc = nub $ nu' [] sc where
    nu' ps (Case n alts) = nub (concatMap (nua ps) alts) \\ [n]
    nu' ps (STerm t)     = nub $ nut ps t
    nu' ps _ = []

    nua ps (ConCase n i args sc) = nub (nu' (ps ++ args) sc) \\ args
    nua ps (ConstCase _ sc) = nu' ps sc
    nua ps (DefaultCase sc) = nu' ps sc

    nut ps (P _ n _) | n `elem` ps = []
                     | otherwise = [n]
    nut ps (App f a) = nut ps f ++ nut ps a
    nut ps (Bind n (Let t v) sc) = nut ps v ++ nut (n:ps) sc
    nut ps (Bind n b sc) = nut (n:ps) sc
    nut ps _ = []

-- Return all called functions, and which arguments are used in each argument position
-- for the call, in order to help reduce compilation time, and trace all unused
-- arguments

findCalls :: SC -> [Name] -> [(Name, [[Name]])]
findCalls sc topargs = nub $ nu' topargs sc where
    nu' ps (Case n alts) = nub (concatMap (nua (n : ps)) alts)
    nu' ps (STerm t)     = nub $ nut ps t
    nu' ps _ = []

    nua ps (ConCase n i args sc) = nub (nu' (ps ++ args) sc) 
    nua ps (ConstCase _ sc) = nu' ps sc
    nua ps (DefaultCase sc) = nu' ps sc

    nut ps (P Ref n _) | n `elem` ps = []
                     | otherwise = [(n, [])] -- tmp
    nut ps fn@(App f a) 
        | (P Ref n _, args) <- unApply fn
             = if n `elem` ps then nut ps f ++ nut ps a
                  else [(n, map argNames args)] ++ concatMap (nut ps) args
        | otherwise = nut ps f ++ nut ps a
    nut ps (Bind n (Let t v) sc) = nut ps v ++ nut (n:ps) sc
    nut ps (Bind n b sc) = nut (n:ps) sc
    nut ps _ = []

    argNames tm = let ns = directUse tm in
                      filter (\x -> x `elem` ns) topargs

-- Find names which are used directly (i.e. not in a function call) in a term

directUse :: Eq n => TT n -> [n]
directUse (P _ n _) = [n]
directUse (Bind n (Let t v) sc) = nub $ directUse v ++ (directUse sc \\ [n])
                                        ++ directUse t
directUse (Bind n b sc) = nub $ directUse (binderTy b) ++ (directUse sc \\ [n])
directUse fn@(App f a) 
    | (P Ref n _, args) <- unApply fn = [] -- need to know what n does with them
    | otherwise = nub $ directUse f ++ directUse a
directUse (Proj x i) = nub $ directUse x
directUse _ = []

-- Find all directly used arguments (i.e. used but not in function calls)

findUsedArgs :: SC -> [Name] -> [Name]
findUsedArgs sc topargs = filter (\x -> x `elem` topargs) (nub $ nu' sc) where
    nu' (Case n alts) = n : concatMap nua alts
    nu' (STerm t)     = directUse t
    nu' _             = []

    nua (ConCase n i args sc) = nu' sc 
    nua (ConstCase _ sc)      = nu' sc
    nua (DefaultCase sc)      = nu' sc

data Phase = CompileTime | RunTime
    deriving (Show, Eq)

-- Generate a simple case tree
-- Work Left to Right at Compile Time 

simpleCase :: Bool -> Bool -> Phase -> FC -> [([Name], Term, Term)] -> TC CaseDef
simpleCase tc cover phase fc [] 
                 = return $ CaseDef [] (UnmatchedCase "No pattern clauses") []
simpleCase tc cover phase fc cs 
      = let proj       = phase == RunTime
            pats       = map (\ (avs, l, r) -> 
                                   (avs, rev phase (toPats tc l), (l, r))) cs
            chkPats    = mapM chkAccessible pats in
            case chkPats of
                OK pats ->
                    let numargs    = length (fst (head pats)) 
                        ns         = take numargs args
                        (tree, st) = runState 
                                         (match (rev phase ns) pats (defaultCase cover)) ([], numargs)
                        t          = CaseDef ns (prune proj tree) (fst st) in
                        if proj then return (stripLambdas t) else return t
                Error err -> Error (At fc err)
    where args = map (\i -> MN i "e") [0..]
          defaultCase True = STerm Erased
          defaultCase False = UnmatchedCase "Error"

          chkAccessible (avs, l, c) = do mapM_ (acc l) avs
                                         return (l, c)

          acc [] n = Error (Inaccessible n) 
          acc (PV x : xs) n | x == n = OK ()
          acc (PCon _ _ ps : xs) n = acc (ps ++ xs) n
          acc (_ : xs) n = acc xs n

rev CompileTime = id
rev _ = reverse

data Pat = PCon Name Int [Pat]
         | PConst Const
         | PV Name
         | PAny
    deriving Show

-- If there are repeated variables, take the *last* one (could be name shadowing
-- in a where clause, so take the most recent).

toPats :: Bool -> Term -> [Pat]
toPats tc f = reverse (toPat tc (getArgs f)) where
   getArgs (App f a) = a : getArgs f
   getArgs _ = []

toPat :: Bool -> [Term] -> [Pat]
toPat tc tms = evalState (mapM (\x -> toPat' x []) tms) []
  where
    toPat' (P (DCon t a) n _) args = do args' <- mapM (\x -> toPat' x []) args
                                        return $ PCon n t args'
    -- Typecase
    toPat' (P (TCon t a) n _) args | tc 
                                   = do args' <- mapM (\x -> toPat' x []) args
                                        return $ PCon n t args'
    toPat' (Constant IType)   [] | tc = return $ PCon (UN "Int")    1 [] 
    toPat' (Constant FlType)  [] | tc = return $ PCon (UN "Float")  2 [] 
    toPat' (Constant ChType)  [] | tc = return $ PCon (UN "Char")   3 [] 
    toPat' (Constant StrType) [] | tc = return $ PCon (UN "String") 4 [] 
    toPat' (Constant PtrType) [] | tc = return $ PCon (UN "Ptr")    5 [] 
    toPat' (Constant BIType)  [] | tc = return $ PCon (UN "Integer") 6 [] 

    toPat' (P Bound n _)      []   = do ns <- get
                                        if n `elem` ns 
                                          then return PAny 
                                          else do put (n : ns)
                                                  return (PV n)
    toPat' (App f a)  args = toPat' f (a : args)
    toPat' (Constant x@(I _)) [] = return $ PConst x 
    toPat' _            _  = return PAny


data Partition = Cons [Clause]
               | Vars [Clause]
    deriving Show

isVarPat (PV _ : ps , _) = True
isVarPat (PAny : ps , _) = True
isVarPat _               = False

isConPat (PCon _ _ _ : ps, _) = True
isConPat (PConst _   : ps, _) = True
isConPat _                    = False

partition :: [Clause] -> [Partition]
partition [] = []
partition ms@(m : _)
    | isVarPat m = let (vars, rest) = span isVarPat ms in
                       Vars vars : partition rest
    | isConPat m = let (cons, rest) = span isConPat ms in
                       Cons cons : partition rest
partition xs = error $ "Partition " ++ show xs

match :: [Name] -> [Clause] -> SC -- error case
                            -> State CS SC
match [] (([], ret) : xs) err 
    = do (ts, v) <- get
         put (ts ++ (map (fst.snd) xs), v)
         case snd ret of
            Impossible -> return ImpossibleCase
            tm -> return $ STerm tm -- run out of arguments
match vs cs err = do let ps = partition cs
                     cs <- mixture vs ps err
                     return cs

mixture :: [Name] -> [Partition] -> SC -> State CS SC
mixture vs [] err = return err
mixture vs (Cons ms : ps) err = do fallthrough <- mixture vs ps err
                                   conRule vs ms fallthrough
mixture vs (Vars ms : ps) err = do fallthrough <- mixture vs ps err
                                   varRule vs ms fallthrough

data ConType = CName Name Int -- named constructor
             | CConst Const -- constant, not implemented yet

data Group = ConGroup ConType -- Constructor
                      [([Pat], Clause)] -- arguments and rest of alternative

conRule :: [Name] -> [Clause] -> SC -> State CS SC
conRule (v:vs) cs err = do groups <- groupCons cs
                           caseGroups (v:vs) groups err

caseGroups :: [Name] -> [Group] -> SC -> State CS SC
caseGroups (v:vs) gs err = do g <- altGroups gs
                              return $ Case v (sort g)
  where
    altGroups [] = return [DefaultCase err]
    altGroups (ConGroup (CName n i) args : cs)
        = do g <- altGroup n i args
             rest <- altGroups cs
             return (g : rest)
    altGroups (ConGroup (CConst c) args : cs) 
        = do g <- altConstGroup c args
             rest <- altGroups cs
             return (g : rest)

    altGroup n i gs = do (newArgs, nextCs) <- argsToAlt gs
                         matchCs <- match (newArgs ++ vs) nextCs err
                         return $ ConCase n i newArgs matchCs
    altConstGroup n gs = do (_, nextCs) <- argsToAlt gs
                            matchCs <- match vs nextCs err
                            return $ ConstCase n matchCs

argsToAlt :: [([Pat], Clause)] -> State CS ([Name], [Clause])
argsToAlt [] = return ([], [])
argsToAlt rs@((r, m) : rest)
    = do newArgs <- getNewVars r
         return (newArgs, addRs rs)
  where 
    getNewVars [] = return []
    getNewVars ((PV n) : ns) = do v <- getVar
                                  nsv <- getNewVars ns
                                  return (v : nsv)
    getNewVars (_ : ns) = do v <- getVar
                             nsv <- getNewVars ns
                             return (v : nsv)
    addRs [] = []
    addRs ((r, (ps, res)) : rs) = ((r++ps, res) : addRs rs)

    uniq i (UN n) = MN i n
    uniq i n = n

getVar :: State CS Name
getVar = do (t, v) <- get; put (t, v+1); return (MN v "e")

groupCons :: [Clause] -> State CS [Group]
groupCons cs = gc [] cs
  where
    gc acc [] = return acc
    gc acc ((p : ps, res) : cs) = 
        do acc' <- addGroup p ps res acc
           gc acc' cs
    addGroup p ps res acc = case p of
        PCon con i args -> return $ addg con i args (ps, res) acc
        PConst cval -> return $ addConG cval (ps, res) acc
        pat -> fail $ show pat ++ " is not a constructor or constant (can't happen)"

    addg con i conargs res [] = [ConGroup (CName con i) [(conargs, res)]]
    addg con i conargs res (g@(ConGroup (CName n j) cs):gs)
        | i == j = ConGroup (CName n i) (cs ++ [(conargs, res)]) : gs
        | otherwise = g : addg con i conargs res gs

    addConG con res [] = [ConGroup (CConst con) [([], res)]]
    addConG con res (g@(ConGroup (CConst n) cs) : gs)
        | con == n = ConGroup (CConst n) (cs ++ [([], res)]) : gs
        | otherwise = g : addConG con res gs

varRule :: [Name] -> [Clause] -> SC -> State CS SC
varRule (v : vs) alts err =
    do let alts' = map (repVar v) alts
       match vs alts' err
  where
    repVar v (PV p : ps , (lhs, res)) = (ps, (lhs, subst p (P Bound v (V 0)) res))
    repVar v (PAny : ps , res) = (ps, res)

prune :: Bool -> -- ^ Convert single brances to projections (only useful at runtime)
         SC -> SC
prune proj (Case n alts) 
    = let alts' = filter notErased (map pruneAlt alts) in
          case alts' of
            [] -> ImpossibleCase
            as@[ConCase cn i args sc] -> if proj then mkProj n 0 args sc
                                                 else Case n as
            as  -> Case n as
    where pruneAlt (ConCase cn i ns sc) = ConCase cn i ns (prune proj sc)
          pruneAlt (ConstCase c sc) = ConstCase c (prune proj sc)
          pruneAlt (DefaultCase sc) = DefaultCase (prune proj sc)

          notErased (DefaultCase (STerm Erased)) = False
          notErased (DefaultCase ImpossibleCase) = False
          notErased _ = True

          mkProj n i []       sc = sc
          mkProj n i (x : xs) sc = mkProj n (i + 1) xs (projRep x n i sc)

          projRep :: Name -> Name -> Int -> SC -> SC
          projRep arg n i (Case x alts)
                | x == arg = ProjCase (Proj (P Bound n Erased) i) 
                                      (map (projRepAlt arg n i) alts)
                | otherwise = Case x (map (projRepAlt arg n i) alts)
          projRep arg n i (ProjCase t alts)
                = ProjCase (projRepTm arg n i t) (map (projRepAlt arg n i) alts)
          projRep arg n i (STerm t) = STerm (projRepTm arg n i t)
          projRep arg n i c = c -- unmatched

          projRepAlt arg n i (ConCase cn t args rhs)
              = ConCase cn t args (projRep arg n i rhs)
          projRepAlt arg n i (ConstCase t rhs)
              = ConstCase t (projRep arg n i rhs)
          projRepAlt arg n i (DefaultCase rhs)
              = DefaultCase (projRep arg n i rhs)

          projRepTm arg n i t = subst arg (Proj (P Bound n Erased) i) t 

prune _ t = t

stripLambdas :: CaseDef -> CaseDef
stripLambdas (CaseDef ns (STerm (Bind x (Lam _) sc)) tm)
    = stripLambdas (CaseDef (ns ++ [x]) (STerm (instantiate (P Bound x Erased) sc)) tm)
stripLambdas x = x




