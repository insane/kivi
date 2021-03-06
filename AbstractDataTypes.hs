module AbstractDataTypes where


import Common
import ParserTypes
import Data.List
import Data.Map as Map
import Debug.Trace


type Tag = Int
type Arity = Int
type NameConstrMapping = Map Name (Tag, Int)

trueTag :: Tag
trueTag = 1

falseTag :: Tag
falseTag = 0

consTag :: Tag
consTag = 3


nilTag :: Tag
nilTag = 2


initialTag :: Tag
initialTag = 4


undefinedTag :: Tag
undefinedTag = -1


primitiveADTs :: [DataType]
primitiveADTs = [("Bool", [("True", trueTag, 0), ("False", falseTag, 0)]),
                 ("List", [("Nil", nilTag, 0), ("Cons", consTag, 2)]),
                 ("Tuple0", [("Tuple0", undefinedTag, 0)]),
                 ("Tuple1", [("Tuple1", undefinedTag, 1)]),
                 ("Tuple2", [("Tuple2", undefinedTag, 2)]),
                 ("Tuple3", [("Tuple3", undefinedTag, 3)]),
                 ("Tuple4", [("Tuple4", undefinedTag, 4)])]


--TODO: make one generic function instead of 3 practically identical ones
--TODO: make it use a map instead of proplists of datatypes
tagFromName :: Name -> [DataType] -> Tag
tagFromName name ((dtname, cs) : types) =
    case findConstrByName name cs of
        Nothing -> tagFromName name types
        Just (n, t, a) -> t
tagFromName tag [] = error $ "Could not find constructor with tag: " ++ show tag


arity :: Int -> [DataType] -> Int
arity tag ((name, cs) : types) =
    case findConstrByTag tag cs of
        Nothing -> arity tag types
        Just (n, t, a) -> a
arity tag [] = error $ "Could not find constructor with tag: " ++ show tag


constructors :: Int -> [DataType] -> [Int]
constructors tag ((name, cs) : types) =
    case findConstrByTag tag cs of
        Nothing -> constructors tag types
        Just (n, t, a) -> [t | (n, t, a) <- cs]
constructors tag [] = error $ "Could not find constructor with tag: " ++ show tag


findConstrByTag :: Int -> [Constructor] -> Maybe Constructor
findConstrByTag tag ((name, tag', arity) : cs) | tag == tag' = Just (name, tag, arity)
                                               | otherwise   = findConstrByTag tag cs
findConstrByTag tag []                                       = Nothing


findConstrByName :: Name -> [Constructor] -> Maybe Constructor
findConstrByName name ((name', tag, arity) : cs) | name == name' = Just (name, tag, arity)
                                                | otherwise     = findConstrByName name cs
findConstrByName name []                                        = Nothing


tag :: PatProgram -> PatProgram
tag (adts, scs) = (adts', scs')
    where
        ((mapping, tag), adts') = mapAccumL tagADT (Map.empty, initialTag) (adts ++ primitiveADTs)
        scs' = [tagSc mapping sc | sc <- scs]


tagADT :: (NameConstrMapping, Tag) -> DataType -> ((NameConstrMapping, Tag), DataType)
tagADT (mapping, curTag) (dtName, cs) =
    ((mapping', curTag'), (dtName, cs'))
    where
        ((mapping', curTag'), cs') = mapAccumL collectTag (mapping, curTag) cs

collectTag :: (NameConstrMapping, Tag) -> Constructor -> ((NameConstrMapping, Tag), Constructor)
collectTag (mapping, curTag) (name, -1, arity) =
    ((Map.insert name (curTag, arity) mapping, curTag + 1), (name, curTag, arity))
collectTag (mapping, curTag) adt@(name, tag, arity) = ((Map.insert name (tag, arity) mapping, curTag), adt)



tagSc :: NameConstrMapping -> PatScDefn -> PatScDefn
tagSc mapping (PatScDefn name eqs) = (PatScDefn name [tagEq mapping eq | eq <- eqs])


tagEq :: NameConstrMapping -> Equation -> Equation
tagEq mapping (patterns, expr) = (patterns', expr')
    where
        patterns' = tagPatterns mapping patterns
        expr' = tagExpr mapping expr


tagPatterns :: NameConstrMapping -> [Pattern] -> [Pattern]
tagPatterns mapping patterns = [tagPattern mapping pattern | pattern <- patterns]


tagPattern :: NameConstrMapping -> Pattern -> Pattern
tagPattern mapping (PConstrName name patterns) =
    PConstr (getPatternTag mapping name) (getPatternArity mapping name) (tagPatterns mapping patterns)
tagPattern mapping pattern = pattern


tagExpr :: NameConstrMapping -> Expr Pattern -> Expr Pattern
tagExpr mapping (EConstrName name) =
    EConstr (getPatternTag mapping name) (getPatternArity mapping name)
tagExpr mapping (EAp e1 e2) = EAp (tagExpr mapping e1) (tagExpr mapping e2)
tagExpr mapping (ELet isRec defns expr) = ELet isRec defns' expr'
    where
        defns' = [(tagPattern mapping pattern, tagExpr mapping rhs) | (pattern, rhs) <- defns]
        expr' = tagExpr mapping expr
tagExpr mapping (ECase expr alts) = ECase expr' alts'
    where
        expr' = tagExpr mapping expr
        alts' = [(tagPattern mapping pattern, tagExpr mapping rhs) | (pattern, rhs) <- alts]
tagExpr mapping (ELam patterns expr) = ELam patterns' expr'
    where
        expr' = tagExpr mapping expr
        patterns' = tagPatterns mapping patterns
tagExpr mapping expr = expr


getPatternTag :: NameConstrMapping -> Name -> Tag
getPatternTag = getPatternConstr fst


getPatternArity :: NameConstrMapping -> Name -> Arity
getPatternArity = getPatternConstr snd


getPatternConstr :: ((Tag, Arity) -> Int) -> NameConstrMapping -> Name -> Int
getPatternConstr f mapping name =
    case Map.lookup name mapping of
        Nothing -> error $ "Could not find constructor: " ++ name
        Just constr -> f constr

