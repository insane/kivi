module TypeChecker(typeCheck) where


import Common
import Data.Map as Map
import Data.Set as Set
import NameSupply
import Data.List
import Debug.Trace


type TypeVarName = String
type TypeEnv = Map Name TypeExpr
type TypeInstanceEnv = Map TypeVarName TypeExpr
type NonGenericSet = Set TypeVarName
type State = (NameSupply, TypeInstanceEnv, TypeEnv, NonGenericSet)
data TypeExpr = TypeVar TypeVarName | TypeOp String [TypeExpr]


instance Eq TypeExpr where
    (TypeVar tvn) == (TypeVar tvn') = tvn == tvn'
    (TypeOp ton args) == (TypeOp ton' args') = ton == ton' && args == args'


type TypedExpr a = (TypeExpr, TypedExpr' a)

data TypedExpr' a = TVar Name
                  | TNum Int
                  | TConstr Int Int
                  | TAp (TypedExpr a) (TypedExpr a)
                  | TLet IsRec [TypedDefn a] (TypedExpr a)
                  | TCase (TypedExpr a) [TypedAlt a]
                  | TCaseSimple (TypedExpr a) [TypedAlt a]
                  | TCaseConstr (TypedExpr a) [TypedAlt a]
                  | TLam [a] (TypedExpr a)
                  | TSelect Int Int a
                  | TError String

type TypedDefn a = (a, TypedExpr a)
type TypedAlt a = (Int, TypedExpr a)
data TypedScDefn a = TypedScDefn Name [a] (TypedExpr a)
type TypedProgram a = ([DataType], [TypedScDefn a])


showTypeExpr :: State -> TypeExpr -> String
showTypeExpr state (TypeVar tvn) =
    case Map.lookup tvn instEnv of
        Just te -> showTypeExpr state te
        Nothing -> tvn
    where
        instEnv = getInstanceEnv state
showTypeExpr state (TypeOp ton args) =
    case args of
        []       -> ton
        [t1, t2] -> showTypeExpr state t1 ++ " " ++ ton ++ " " ++ showTypeExpr state t2


arrow :: TypeExpr -> TypeExpr -> TypeExpr
arrow t1 t2 = TypeOp "->" [t1, t2]


int :: TypeExpr
int = TypeOp "int" []


bool :: TypeExpr
bool = TypeOp "bool" []


cross :: TypeExpr -> TypeExpr -> TypeExpr
cross t1 t2 = TypeOp "cross" [t1, t2]


list :: TypeExpr -> TypeExpr
list t = TypeOp "list" [t]


typeCheck :: CoreProgram -> TypedProgram Name
typeCheck (adts, scs) = (adts, scs')
    where (state, scs') = mapAccumL typeCheckSc initialState scs


typeCheckSc :: State -> CoreScDefn -> (State, TypedScDefn Name)
typeCheckSc state (ScDefn name args expr) = (state, TypedScDefn name args expr')
    where (state', expr') = typeCheckExpr state expr


typeCheckExpr :: State -> CoreExpr -> (State, TypedExpr Name)
typeCheckExpr state (EVar v) = (state', (typeExpr, TVar v))
    where (state', typeExpr) = getType state v
typeCheckExpr state (ENum n) = (state, (int, TNum n))
typeCheckExpr state (EAp e1 e2) = (state4, (resType', TAp (funType', e1') (argType', e2')))
    where
        (state1, (funType, e1')) = typeCheckExpr state e1
        (state2, (argType, e2')) = typeCheckExpr state1 e2
        (state3, resType) = newTypeVariable state2
        (state4, TypeOp ton [argType', resType'], funType') = unify state3 (argType `arrow` resType) funType
-- Here we assume that lambdas has already been split and contain one argument only
typeCheckExpr state lambda@(ELam [v] expr) = (state4, (resType, TLam [v] typedExpr))
    where
        (state1, argType@(TypeVar tvn)) = newTypeVariable state
        state2 = putEnv state1 $ Map.insert v argType $ getEnv state1
        state3 = putNonGeneric state2 $ Set.insert tvn $ getNonGeneric state2
        (state4, typedExpr@(exprType, expr')) = typeCheckExpr state3 expr
        resType = argType `arrow` exprType
typeCheckExpr state expr@(ELet False defns body) = typeCheckLet state expr
typeCheckExpr state expr@(ELet True defns body)  = typeCheckLetrec state expr


typeCheckLet :: State -> CoreExpr -> (State, TypedExpr Name)
typeCheckLet state (ELet False defns expr) = (state2, (exprType, TLet False defns' typedExpr))
    where
        (state1, defns') = mapAccumL typeCheckDefn state defns
        (state2, typedExpr@(exprType, expr')) = typeCheckExpr state1 expr


typeCheckLetrec :: State -> CoreExpr -> (State, TypedExpr Name)
typeCheckLetrec state (ELet True defns expr) = (state3, (exprType, TLet True defns' typedExpr))
    where
        state1 = foldl collectDefn state defns
        (state2, defns') = mapAccumL typeCheckRecDefn state1 defns
        (state3, typedExpr@(exprType, expr')) = typeCheckExpr state2 expr

        collectDefn state (v, defn) = state3
            where
                (state1, tv@(TypeVar tvn)) = newTypeVariable state
                state2 = putEnv state1 $ Map.insert v tv $ getEnv state1
                state3 = putNonGeneric state2 $ Set.insert tvn $ getNonGeneric state2


typeCheckDefn :: State -> CoreDefn -> (State, TypedDefn Name)
typeCheckDefn state (v, defn) = (state2, (v, typedDefn))
    where
        (state1, typedDefn@(defnType, defn')) = typeCheckExpr state defn
        state2 = putEnv state1 $ Map.insert v defnType $ getEnv state1


typeCheckRecDefn :: State -> CoreDefn -> (State, TypedDefn Name)
typeCheckRecDefn state (v, defn) = (state3, (v, typedDefn))
    where
        (state1, typedDefn@(defnType, defn')) = typeCheckExpr state defn

        (Just varType) = Map.lookup v $ getEnv state1
        (state2, varType', defnType') = unify state1 varType defnType

        state3 = putEnv state2 $ Map.insert v varType' $ getEnv state2


getType :: State -> Name -> (State, TypeExpr)
getType state v =
    case (Map.lookup v $ getEnv state) of
        (Just te) -> (putEnv state $ getEnv state, te')
            where
                (state', te') = fresh state te
        Nothing  -> error $ "Undefined symbol: " ++ v


fresh :: State -> TypeExpr -> (State, TypeExpr)
fresh state te = fresh' (putEnv state initialTypeEnv) te


fresh' :: State -> TypeExpr -> (State, TypeExpr)
fresh' state te =
    case prune state te of
        (state', typeVar@(TypeVar tvn))    -> freshVar state' typeVar
        (state', typeOp@(TypeOp ton args)) -> freshOper state' typeOp


freshVar :: State -> TypeExpr -> (State, TypeExpr)
freshVar state tv@(TypeVar tvn) =
    case isGeneric state tvn of
        True  -> (state2, tv')
            where
                (state1, tv') = newTypeVariable state
                state2 = putEnv state1 $ Map.insert tvn tv' $ getEnv state1
        False -> (state, tv)


freshOper :: State -> TypeExpr -> (State, TypeExpr)
freshOper state (TypeOp ton args) = (state, TypeOp ton args')
    where
        (state', args') = mapAccumL fresh' state args


isGeneric :: State -> TypeVarName -> Bool
isGeneric state tvn = not $ Set.member tvn $ getNonGeneric state


newTypeVariable :: State -> (State, TypeExpr)
newTypeVariable state = (state', TypeVar name)
    where
        (ns', name) = getName (getNameSupply state) "t"
        state' = putNameSupply state ns'


prune :: State -> TypeExpr -> (State, TypeExpr)
prune state typeVar@(TypeVar v) =
    case Map.lookup v instEnv of
        (Just inst) -> (state2, inst')
            where
                (state1, inst') = prune state inst
                state2 = putInstanceEnv state1 $ Map.insert v inst' $ instEnv
        Nothing -> (state, typeVar)
    where
        instEnv = getInstanceEnv state
prune state typeOp@(TypeOp op args) = (state, typeOp)


unify :: State -> TypeExpr -> TypeExpr -> (State, TypeExpr, TypeExpr)
unify state te1 te2 = unify' state2 te1' te2'
    where
        (state1, te1') = prune state te1
        (state2, te2') = prune state1 te2


unify' :: State -> TypeExpr -> TypeExpr -> (State, TypeExpr, TypeExpr)
unify' state tv@(TypeVar tvn) te =
    case occurs of
        True -> error "Recursive unification"
        False -> (state2, tv, te)
            where
                state2 = putInstanceEnv state1 $ Map.insert tvn te $ getInstanceEnv state1
    where
        (state1, occurs) = occursInType state tv te
unify' state to@(TypeOp ton args) tv@(TypeVar tvn) = unify' state tv to
unify' state to1@(TypeOp n1 as1) to2@(TypeOp n2 as2) =
    case n1 /= n2 || length as1 /= length as2 of
        True -> error $ "Type mismatch: " ++ showTypeExpr state to1 ++ " and " ++ showTypeExpr state to2
        False -> (state', TypeOp n1 a1', TypeOp n2 a2')
            where
                (state', a1', a2') = foldl unifyArgs (state, [], []) $ zip as1 as2


unifyArgs :: (State, [TypeExpr], [TypeExpr])
          -> (TypeExpr, TypeExpr)
          -> (State, [TypeExpr], [TypeExpr])
unifyArgs (state, tacc1, tacc2) (te1, te2) =
    (state', tacc1 ++ [te1'], tacc2 ++ [te2'])
    where
        (state', te1', te2') = unify state te1 te2


occursInType :: State -> TypeExpr -> TypeExpr -> (State, Bool)
occursInType state tv@(TypeVar tvn) te =
    case pruned of
        TypeVar tvn' | tvn == tvn' -> (state', True)
        TypeOp ton args            -> occursInArgs state' tv args
        _                          -> (state', False)
    where
        (state', pruned) = prune state te


occursInArgs :: State -> TypeExpr -> [TypeExpr] -> (State, Bool)
occursInArgs state tv@(TypeVar tvn) typeExprs = foldl occursInArg (state, False) typeExprs
    where
        occursInArg (state, occurs) te = (state', occurs || oc)
            where
                (state', oc) = occursInType state tv te


----------------------------- local helper functions

initialTypeInstanceEnv :: TypeInstanceEnv
initialTypeInstanceEnv = Map.empty


initialTypeEnv :: TypeEnv
initialTypeEnv = Map.empty


initialNonGenericSet :: NonGenericSet
initialNonGenericSet = Set.empty


initialState :: State
initialState = (initialNameSupply, initialTypeInstanceEnv, initialTypeEnv, initialNonGenericSet)


getNameSupply :: State -> NameSupply
getNameSupply (ns, iEnv, env, nonGeneric) = ns


putNameSupply :: State -> NameSupply -> State
putNameSupply (ns, iEnv, env, nonGeneric) ns' = (ns', iEnv, env, nonGeneric)


getInstanceEnv :: State -> TypeInstanceEnv
getInstanceEnv (ns, iEnv, env, nonGeneric) = iEnv


putInstanceEnv :: State -> TypeInstanceEnv -> State
putInstanceEnv (ns, iEnv, env, nonGeneric) iEnv' = (ns, iEnv', env, nonGeneric)


getEnv :: State -> TypeEnv
getEnv (ns, iEnv, env, nonGeneric) = env


putEnv :: State -> TypeEnv -> State
putEnv (ns, iEnv, env, nonGeneric) env' = (ns, iEnv, env', nonGeneric)


getNonGeneric :: State -> NonGenericSet
getNonGeneric (ns, iEnv, env, nonGeneric) = nonGeneric


putNonGeneric :: State -> NonGenericSet -> State
putNonGeneric (ns, iEnv, env, nonGeneric) nonGeneric' = (ns, iEnv, env, nonGeneric')

