{-# LANGUAGE FlexibleInstances,MultiParamTypeClasses,GADTs,RankNTypes #-}
module MemoryModel.Snow where

import MemoryModel
import DecisionTree
import TypeDesc
import ConditionList

import Language.SMTLib2
--import qualified Data.Graph.Inductive as Gr
import Data.Map as Map hiding (foldl)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Foldable
import Data.Traversable
import Prelude hiding (foldl1,foldl,mapM_,concat,mapM,sequence_)
import Data.Bits
import Control.Monad.Trans
import Data.Maybe (catMaybes)
import Data.Monoid
import qualified Data.List as List
import Debug.Trace

import MemoryModel.Snow.Object

type BVPtr = BV64
type BVByte = BitVector BVUntyped

data SnowMemory mloc ptr
  = SnowMemory { snowStructs :: Map String [TypeDesc]
               , snowProgram :: [(SMTExpr Bool,MemoryInstruction mloc ptr)]
               , snowGlobal :: SnowLocation ptr
               , snowPointers :: Map ptr [(SMTExpr Bool,PointerContent (Integer,PtrIndex))]
               , snowLocations :: Map mloc (SnowLocation ptr)
               , snowPointerConnections :: Map ptr [(ptr,SMTExpr Bool)]
               , snowLocationConnections :: Map mloc [(mloc,SMTExpr Bool)]
               , snowNextObject :: Integer
               , snowErrors :: [(ErrorDesc,SMTExpr Bool)]
               }

data SnowLocation ptr
  = SnowLocation { snowObjects :: Map Integer [(SMTExpr Bool,Object ptr)] }

data SnowPointer ptr
  = DirectPointer [(SMTExpr Bool,Maybe (Integer,PtrIndex))]
  | PointerSelect [(SMTExpr Bool,ptr)]
  | PointerCast TypeDesc TypeDesc ptr
  | PointerIndex [DynNum] ptr

type ObjectUpdate mloc ptr = (mloc,Integer,[(SMTExpr Bool,Object ptr)])
type PointerUpdate ptr = (ptr,[(SMTExpr Bool,PointerContent (Integer,PtrIndex))])

instance (Ord ptr,Show ptr) => Monoid (SnowLocation ptr) where
  mempty = SnowLocation { snowObjects = Map.empty }
  mappend l1 l2 = SnowLocation { snowObjects = Map.unionWith (\x y -> simplifyCondList $ mergeCondList x y) (snowObjects l1) (snowObjects l2) }

mkGlobal :: MemContent -> SMT (Object ptr)
mkGlobal cont = do
  glob <- mkGlobal' cont
  return $ Bounded $ StaticArrayObject [glob]
  where
    mkGlobal' (MemCell w v) = do
      obj <- defConstNamed "global" (constantAnn (BitVector v) w)
      return $ WordObject obj
    mkGlobal' (MemArray els) = do
      els' <- mapM mkGlobal' els
      return $ StaticArrayObject els'
    mkGlobal' MemNull = return (Pointer NullPointer)

instance (Ord mloc,Ord ptr,Show ptr,Show mloc) => MemoryModel (SnowMemory mloc ptr) mloc ptr where
  memNew _ _ _ structs globals = do
    (globs,ptrs,next) <- foldlM (\(loc,ptrs,next) (ptr,tp,cont) -> do
                                    glob <- case cont of
                                      Just cont' -> mkGlobal cont'
                                    return (loc { snowObjects = Map.insert next [(constant True,glob)] (snowObjects loc)
                                                },Map.insert ptr [(constant True,ValidPointer (next,[(tp,[])]))] ptrs,succ next)
                                ) (SnowLocation Map.empty,Map.empty,0) globals
    --trace (unlines $ snowDebugLocation "globals" globs) $ return ()
    return $ SnowMemory { snowStructs = structs
                        , snowProgram = []
                        , snowLocations = Map.empty
                        , snowPointers = ptrs
                        , snowPointerConnections = Map.empty
                        , snowLocationConnections = Map.empty
                        , snowGlobal = globs
                        , snowNextObject = next
                        , snowErrors = []
                        }
  makeEntry _ mem loc = {-trace ("Make entry: "++show loc) $-} return $ mem { snowLocations = Map.insert loc (snowGlobal mem) (snowLocations mem) }
  addProgram mem act prev_locs prog ptrs = do
    --trace ("Adding program: "++show prog++" "++show prev_locs) $ return ()
    let rprog = fmap (\instr -> (act,instr)) prog
        mem1 = mem { snowProgram = (snowProgram mem)++rprog }
    (mem2,ptr_upds,obj_upds) <- foldlM (\(cmem,cptr_upds,cobj_upds) instr -> do
                                           (obj_upd',ptr_upd',next) <- initUpdates (snowStructs cmem) (snowNextObject cmem) instr
                                           return (cmem { snowNextObject = next },
                                                   case ptr_upd' of
                                                     Nothing -> cptr_upds
                                                     Just up -> up:cptr_upds,
                                                   case obj_upd' of
                                                     Nothing -> cobj_upds
                                                     Just up -> up:cobj_upds)
                                       ) (mem1,[],[]) prog
    mem3 <- applyUpdates ptr_upds obj_upds (snowProgram mem2) mem2
    applyUpdates (Map.toList $ snowPointers mem1) [ (prev_loc,n,lst)
                                                  | prev_loc <- prev_locs,
                                                    (n,lst) <- case Map.lookup prev_loc (snowLocations mem2) of
                                                      Nothing -> []
                                                      Just prev_loc_cont -> Map.toList $ snowObjects prev_loc_cont
                                                  ] rprog mem3
  connectLocation mem _ cond loc_from loc_to = do
    --trace ("Connecting location "++show loc_from++" with "++show loc_to) $ return ()
    let cloc = case Map.lookup loc_from (snowLocations mem) of
          Just l -> l
          Nothing -> SnowLocation Map.empty
        mem1 = mem { snowLocationConnections = Map.insertWith (++) loc_from [(loc_to,cond)] (snowLocationConnections mem) }
        obj_upd = [ (loc_to,obj,[ (cond .&&. cond',obj) | (cond',obj) <- assign])
                  | (obj,assign) <- Map.toList $ snowObjects cloc ]
        obj_upd' = concat $ fmap (connectObjectUpdate (snowLocationConnections mem1)) obj_upd
    applyUpdates [] obj_upd' (snowProgram mem1) mem1
  connectPointer mem _ cond ptr_from ptr_to = do
    --trace ("Connecting pointer "++show ptr_from++" with "++show ptr_to++"("++show cond++")") $ return ()
    let mem1 = mem { snowPointerConnections = Map.insertWith (++) ptr_from [(ptr_to,cond)] (snowPointerConnections mem) }
        ptr_upd = case Map.lookup ptr_from (snowPointers mem1) of
          Just assign -> connectPointerUpdate (snowPointerConnections mem1)
                         (ptr_to,[ (cond .&&. cond',obj_p) | (cond',obj_p) <- assign ])
          Nothing -> []
    --trace ("Connections: "++show (snowPointerConnections mem1)) (return ())
    applyUpdates ptr_upd [] (snowProgram mem1) mem1
  memoryErrors mem _ _ = snowErrors mem
  debugMem mem _ _ = snowDebug mem

applyUpdates :: (Ord ptr,Ord mloc,Show mloc,Show ptr) => [PointerUpdate ptr] -> [ObjectUpdate mloc ptr] -> [(SMTExpr Bool,MemoryInstruction mloc ptr)] -> SnowMemory mloc ptr -> SMT (SnowMemory mloc ptr)
applyUpdates [] [] _ mem = return mem
applyUpdates ptr_upds obj_upds instrs mem = do
  let ptr_upds' = fmap (\(ptr,upd) -> (ptr,simplifyCondList upd)) ptr_upds
      obj_upds' = fmap (\(loc,obj_p,upd) -> (loc,obj_p,simplifyCondList upd)) obj_upds
  --trace (unlines $ listHeader "Pointer updates: " (fmap show ptr_upds')) (return ())
  --trace (unlines $ listHeader "Object updates: " (fmap show obj_upds')) (return ())
  let mem1 = foldl (\cmem (ptr,assign)
                    -> cmem { snowPointers = Map.insertWith mergeCondList ptr assign (snowPointers cmem)
                            }) mem ptr_upds'
      mem2 = foldl (\cmem (loc,obj_p,assign)
                     -> cmem { snowLocations = Map.insertWith mappend loc
                                               (SnowLocation { snowObjects = Map.singleton obj_p assign
                                                             }) (snowLocations cmem)
                             }) mem1 obj_upds'
  applyUpdates' ptr_upds' obj_upds' [] instrs mem2
  --mem1 <- foldlM (\cmem obj_upd -> applyObjectUpdate obj_upd cmem) mem (concat $ fmap (connectObjectUpdate (snowLocationConnections mem)) obj_upds)
  --mem2 <- foldlM (\cmem ptr_upd -> applyPointerUpdate ptr_upd cmem) mem1 (concat $ fmap (connectPointerUpdate (snowLocationConnections mem1) (snowPointerConnections mem1)) ptr_upds)
  --return mem2

applyUpdates' :: (Ord ptr,Ord mloc,Show mloc,Show ptr) => [PointerUpdate ptr] -> [ObjectUpdate mloc ptr] -> [(SMTExpr Bool,MemoryInstruction mloc ptr)] -> [(SMTExpr Bool,MemoryInstruction mloc ptr)] -> SnowMemory mloc ptr -> SMT (SnowMemory mloc ptr)
applyUpdates' _ _ _ [] mem = return mem
applyUpdates' ptr_upds obj_upds done ((act,i):is) mem = do
  let loc = memInstrSrc i
      loc_objs = case loc of
        Nothing -> Map.empty
        Just rloc -> case Map.lookup rloc (snowLocations mem) of
          Just (SnowLocation { snowObjects = x }) -> x
          Nothing -> Map.empty
  r1 <- foldlM (\(cobj_up,cptr_up,cerrs) ptr_upd -> do
                   (obj_upd',ptr_upd',nerrs) <- updatePointer (snowStructs mem) (snowPointers mem) loc_objs ptr_upd act i
                   return (obj_upd'++cobj_up,
                           (case ptr_upd' of
                               Nothing -> []
                               Just up -> [up])++cptr_up,
                           nerrs++cerrs)
               ) ([],[],[]) ptr_upds
  (nobj_upd,nptr_upd,errs) <- foldlM (\(cobj_up,cptr_up,cerrs) obj_upd -> do
                                         (obj_upd',ptr_upd',nerrs) <- updateObject (snowStructs mem) (snowPointers mem) loc_objs obj_upd act i
                                         return (obj_upd'++cobj_up,
                                                 case ptr_upd' of
                                                   Nothing -> cptr_up
                                                   Just up -> up:cptr_up,
                                                 nerrs++cerrs)
                                     ) r1 obj_upds
  let nobj_upd' = concat $ fmap (connectObjectUpdate (snowLocationConnections mem)) nobj_upd
      nptr_upd' = concat $ fmap (connectPointerUpdate (snowPointerConnections mem)) nptr_upd
  mem1 <- applyUpdates nptr_upd' nobj_upd' (done++[(act,i)]) (mem { snowErrors = errs++(snowErrors mem) })
  applyUpdates' (ptr_upds++nptr_upd') (obj_upds++nobj_upd') (done++[(act,i)]) is mem1

connectPointerUpdate :: (Ord ptr)
                         => Map ptr [(ptr,SMTExpr Bool)]
                         -> PointerUpdate ptr
                         -> [PointerUpdate ptr]
connectPointerUpdate conns_ptr x@(ptr,assign)
  = let res_ptr = case Map.lookup ptr conns_ptr of
          Nothing -> []
          Just ptrs -> [ (ptr',[(cond' .&&. cond,trg)
                               | (cond,trg) <- assign ])
                       | (ptr',cond') <- ptrs ]
    in x:(concat $ fmap (connectPointerUpdate conns_ptr) res_ptr)

connectObjectUpdate :: Ord mloc
                       => Map mloc [(mloc,SMTExpr Bool)]
                       -> ObjectUpdate mloc ptr
                       -> [ObjectUpdate mloc ptr]
connectObjectUpdate mp x@(loc,obj_p,assign) = case Map.lookup loc mp of
  Nothing -> [x]
  Just locs -> x:(concat $ fmap (connectObjectUpdate mp)
                  [ (loc',obj_p,[ (cond .&&. cond',obj) | (cond',obj) <- assign ]) | (loc',cond) <- locs ])

initUpdates :: Map String [TypeDesc]
                -> Integer
                -> MemoryInstruction mloc ptr
                -> SMT (Maybe (ObjectUpdate mloc ptr),
                        Maybe (PointerUpdate ptr),
                        Integer)
initUpdates structs next_obj instr = case instr of
  MINull tp ptr -> return (Nothing,Just (ptr,[(constant True,NullPointer)]),next_obj)
  MIAlloc mfrom tp num ptr mto -> do
    obj <- allocaObject structs tp num
    return (Just (mto,next_obj,[(constant True,obj)]),
            Just (ptr,[(constant True,ValidPointer (next_obj,[(tp,[])]))]),
            succ next_obj)
  _ -> return (Nothing,Nothing,next_obj)

updatePointer :: (Show ptr,Show mloc,Eq mloc,Ord ptr)
                 => Map String [TypeDesc]                             -- ^ All struct types
                 -> Map ptr [(SMTExpr Bool,PointerContent (Integer,PtrIndex))] -- ^ All the pointers at the location (needed for pointer comparisons)
                 -> Map Integer [(SMTExpr Bool,Object ptr)]           -- ^ All objects at the location
                 -> PointerUpdate ptr                                 -- ^ The pointer update to be applied
                 -> SMTExpr Bool                                      -- ^ The execution condition of the instruction
                 -> MemoryInstruction mloc ptr
                 -> SMT ([ObjectUpdate mloc ptr],
                         Maybe (PointerUpdate ptr),
                         [(ErrorDesc,SMTExpr Bool)])
updatePointer structs all_ptrs all_objs (new_ptr,new_conds) act instr = case instr of
  MILoad mfrom ptr res
    | ptr==new_ptr -> do
      let sz = extractAnnotation res
      errs <- mapM (\(cond,src) -> do
                       errs <- mapM (\((obj_p,idx),cond') -> do
                                        let ObjAccessor access = ptrIndexGetAccessor structs idx
                                        case Map.lookup obj_p all_objs of
                                          --Nothing -> error $ "Object "++show obj_p++" not found at location "++show mfrom
                                          Nothing -> return [] -- TODO: Is this sound?
                                          Just objs -> do
                                            errs <- mapM (\(cond'',obj) -> do
                                                             let (_,loaded,errs) = access
                                                                                   (\obj' -> let (res,errs) = loadObject sz obj'
                                                                                             in (obj',[(res,constant True)],errs)
                                                                                   ) obj
                                                             comment $ "Load from "++show ptr
                                                             mapM_ (\(loaded',cond''') -> assert $ (and' `app` [cond,cond',cond'',cond''']) .=>. (res .==. loaded')
                                                                   ) loaded
                                                             return errs
                                                         ) objs
                                            return [ (err,app and' [act,c,cond',cond]) | (err,c) <- concat errs ]
                                    ) (validPointers src)
                       return $ concat errs ++ [ (NullDeref,cond .&&. cond') | cond' <- nullPointers src ]
            ) new_conds
      return ([],Nothing,concat errs)
    | otherwise -> return ([],Nothing,[])
  MILoadPtr mfrom ptr_from ptr_to
    | ptr_from==new_ptr -> do
      let (nptr,errs)
            = concatPairs $ concat $
              fmap (\(cond,src)
                    -> [ let ObjAccessor access = ptrIndexGetAccessor structs idx
                         in case Map.lookup obj_p all_objs of
                           Just objs'
                             -> concatPairs $
                                fmap (\(cond'',obj)
                                      -> let (_,loaded,errs) = access
                                                               (\obj' -> let (res,errs) = loadPtr obj'
                                                                         in (obj',[(res,constant True)],errs)
                                                               ) obj
                                         in (concat [ case loaded' of
                                                         NullPointer -> [(and' `app` [cond,cond',cond'',cond'''],NullPointer)]
                                                         ValidPointer p -> case Map.lookup p all_ptrs of
                                                           Just dests -> [(and' `app` [cond,cond',cond'',cond''',cond''''],d)
                                                                         | (cond'''',d) <- dests ]
                                                    | (loaded',cond''') <- loaded ],errs)
                                     ) objs'
                           Nothing -> ([],[]) -- TODO: Is this sound?
                       | ((obj_p,idx),cond') <- validPointers src ]++
                       [ ([],[(NullDeref,cond .&&. cond')]) | cond' <- nullPointers src ]
                   ) new_conds
      case nptr of
        [] -> return ([],Nothing,errs)
        xs -> return ([],Just (ptr_to,xs),errs)
    | otherwise -> return ([],Nothing,[])
  MIStore mfrom val ptr_to mto
    | ptr_to==new_ptr -> do
      let result
            = [ (mto,obj_p,[ (cond,obj) | (cond,obj,_) <- res],concat [ [(desc,app and' [act,cond,cond',c]) | (desc,c) <- errs] | (cond,_,errs) <- res])
              | (cond,p) <- new_conds,
                ((obj_p,idx),cond') <- validPointers p,
                let ObjAccessor access = ptrIndexGetAccessor structs idx,
                objs' <- case Map.lookup obj_p all_objs of
                  Just x -> [x]
                  --Nothing -> error $ "Can't find object "++show obj_p++" in "++show all_objs++" @"++show mfrom
                  Nothing -> [] -- TODO: Is this sound?
              , let res = [ (app and' [cond,cond',cond''],nobj,errs)
                          | (cond'',obj) <- objs',
                            let (nobj,_,errs) = access (\obj' -> let (res,errs) = storeObject val obj'
                                                                 in (res,[((),constant True)],errs)
                                                       ) obj
                          ]
              ]
      return ([ (mto,obj_p,upds) | (mto,obj_p,upds,_) <- result ],Nothing,
              concat [ errs | (_,_,_,errs) <- result ]++[ (NullDeref,cond .&&. cond') | (cond,p) <- new_conds, cond' <- nullPointers p ])
    | otherwise -> return ([],Nothing,[])
  MIStorePtr mfrom ptr_from ptr_to mto
    | ptr_from==new_ptr -> case Map.lookup ptr_to all_ptrs of
      Just dests -> let result = [ (mto,obj_p,[ (app and' [cond,cond',cond''],nobj,errs)
                                              | (cond'',obj) <- objs',
                                                let (nobj,_,errs) = access (\obj' -> let (res,errs) = storePtr (ValidPointer ptr_from) obj'
                                                                                     in (res,[((),constant True)],errs)
                                                                           ) obj
                                              ])
                                 | (cond,p) <- dests,
                                   ((obj_p,idx),cond') <- validPointers p,
                                   let ObjAccessor access = ptrIndexGetAccessor structs idx,
                                   objs' <- case Map.lookup obj_p all_objs of
                                     Just x -> [x]
                                     Nothing -> [] -- TODO: Is this sound?
                                 ]
                    in return ([(mto,obj_p,[(cond,nobj) | (cond,nobj,_) <- conds ]) | (mto,obj_p,conds) <- result ],Nothing,
                               concat $ concat [ [ [ (err,cond .&&. err_cond) | (err,err_cond) <- errs ] | (cond,_,errs) <- conds ] | (_,_,conds) <- result ])
      Nothing -> return ([],Nothing,[])
    | ptr_to==new_ptr
      -> return ([ (mto,obj_p,[ (app and' [cond,cond',cond''],nobj)
                              | (cond'',obj) <- objs',
                                let (nobj,_,errs) = access (\obj' -> let (res,errs) = storePtr (ValidPointer ptr_from) obj'
                                                                     in (res,[((),constant True)],errs)
                                                           ) obj
                              ])
                 | (cond,p) <- new_conds,
                   ((obj_p,idx),cond') <- validPointers p,
                   let ObjAccessor access = ptrIndexGetAccessor structs idx
                       Just objs' = Map.lookup obj_p all_objs
                 ],Nothing,[ (NullDeref,cond .&&. cond') | (cond,p) <- new_conds, cond' <- nullPointers p ])
    | otherwise -> return ([],Nothing,[])
  MICompare p1 p2 res
    | p1==new_ptr -> case Map.lookup p2 all_ptrs of
      Just a2 -> compare' new_conds a2
      Nothing -> return ([],Nothing,[])
    | p2==new_ptr -> case Map.lookup p1 all_ptrs of
      Just a1 -> compare' new_conds a1
      Nothing -> return ([],Nothing,[])
    | otherwise -> return ([],Nothing,[])
    where
      compare' a1 a2 = do
        comment $ "Compare "++show p1++" and "++show p2
        sequence_ [ assert $ (c1 .&&. c2) .=>.
                    (res .==. (ptrCompare (\(o1,i1) (o2,i2) -> if o1==o2
                                                               then (case ptrIndexEq i1 i2 of
                                                                        Left r -> constant r
                                                                        Right c -> c)
                                                               else constant False
                                          ) ptr1 ptr2))
                  | (c1,ptr1) <- a1,
                    (c2,ptr2) <- a2 ]
        return ([],Nothing,[])
  MISelect cases ptr_to -> case List.find (\(_,ptr_from) -> ptr_from==new_ptr) cases of
    Nothing -> return ([],Nothing,[])
    Just (cond,_) -> return ([],Just (ptr_to,[(cond .&&. cond',src)
                                             | (cond',src) <- new_conds ]),[])
  MICast tp_from tp_to ptr_from ptr_to
    | ptr_from==new_ptr
      -> return ([],Just (ptr_to,[ case src of
                                      NullPointer -> (c,NullPointer)
                                      ValidPointer (obj_p,idx) -> (c,ValidPointer (obj_p,ptrIndexCast structs tp_to idx))
                                 | (c,src) <- new_conds ]),[])
    | otherwise -> return ([],Nothing,[])
  MIIndex _ _ idx ptr_from ptr_to
    | ptr_from==new_ptr
      -> return ([],Just (ptr_to,[ case src of
                                      NullPointer -> (c,NullPointer)
                                      ValidPointer (obj_p,idx') -> (c,ValidPointer (obj_p,ptrIndexIndex idx idx'))
                                 | (c,src) <- new_conds ]),[])
    | otherwise -> return ([],Nothing,[])
  MIStrLen mfrom ptr lenvar
    | ptr==new_ptr -> do
      let sz = extractAnnotation lenvar
      errs <- mapM (\(cond,src) -> do
                       errs <- mapM (\((obj_p,idx),cond') -> do
                                        let (idx',(last_tp,idx_last)) = splitLast idx
                                            (idx_last',off) = splitLast idx_last
                                            idx'' = idx'++[(last_tp,idx_last')]
                                            ObjAccessor access = ptrIndexGetAccessor structs idx''
                                        case Map.lookup obj_p all_objs of
                                          --Nothing -> error $ "Object "++show obj_p++" not found at location "++show mfrom
                                          Nothing -> return [] -- TODO: Is this sound?
                                          Just objs -> do
                                            errs <- mapM (\(cond'',obj) -> do
                                                             let (_,len,errs) = access
                                                                                (\obj' -> let (res,errs) = strlen sz off obj'
                                                                                          in (obj',[(res,constant True)],errs)
                                                                                ) obj
                                                             comment $ "Strlen of "++show ptr
                                                             mapM_ (\(len',cond''') -> assert $ (and' `app` [cond,cond',cond'',cond''']) .=>. (lenvar .==. len')
                                                                   ) len
                                                             return errs
                                                         ) objs
                                            return [ (err,app and' [act,c,cond',cond]) | (err,c) <- concat errs ]
                                    ) (validPointers src)
                       return $ concat errs ++ [ (NullDeref,cond .&&. cond') | cond' <- nullPointers src ]
                   ) new_conds
      return ([],Nothing,concat errs)
    | otherwise -> return ([],Nothing,[])
  {-MICopy mfrom ptr_from ptr_to opts mto
    | ptr_from==new_ptr -> case Map.lookup ptr_to all_ptrs of
      Just dests -> do
        let res = [ (mto,obj_p,[ (cond .&&. cond',nobj)
                               | (cond',obj) <- objs',
                                 let (nobj,_,errs) = access
                                       | (cond,Just (obj_p,idx)) <- new_conds
                , let ObjAccessor access = ptrIndexGetAccessor structs idx
                ]
      return ([],Nothing,[])
    | otherwise -> return ([],Nothing,[])-}
  _ -> return ([],Nothing,[])

concatPairs :: [([a],[b])] -> ([a],[b])
concatPairs xs = (concat $ fmap fst xs,concat $ fmap snd xs)

splitLast :: [a] -> ([a],a)
splitLast [x] = ([],x)
splitLast (x:xs) = let (xs',last) = splitLast xs
                   in (x:xs',last)

updateObject :: (Eq mloc,Ord ptr,Show ptr,Show mloc)
                => Map String [TypeDesc]
                -> Map ptr [(SMTExpr Bool,PointerContent (Integer,PtrIndex))]
                -> Map Integer [(SMTExpr Bool,Object ptr)]
                -> ObjectUpdate mloc ptr
                -> SMTExpr Bool
                -> MemoryInstruction mloc ptr
                -> SMT ([ObjectUpdate mloc ptr],Maybe (PointerUpdate ptr),[(ErrorDesc,SMTExpr Bool)])
updateObject structs all_ptrs all_objs (loc,new_obj,new_conds) act instr = case instr of
  MILoad mfrom ptr res
    | mfrom==loc -> case Map.lookup ptr all_ptrs of
      Just srcs -> do
        let sz = extractAnnotation res
        mapM_ (\(cond,src)
               -> mapM_ (\((obj_p,idx),cond')
                         -> if obj_p==new_obj
                            then mapM_ (\(cond'',obj) -> do
                                           let ObjAccessor access = ptrIndexGetAccessor structs idx
                                               (_,loaded,errs) = access
                                                                 (\obj' -> let (res,errs) = loadObject sz obj'
                                                                           in (obj',[(res,constant True)],errs)
                                                                 ) obj
                                           comment $ "Load from "++show ptr++" (object update)"
                                           mapM_ (\(loaded',cond''') -> assert $ (and' `app` [cond,cond',cond'',cond''']) .=>. (res .==. loaded')
                                                 ) loaded
                                       ) new_conds
                            else return ()
                        ) (validPointers src)
              ) srcs
        return ([],Nothing,[])
      --Nothing -> return ([],Nothing) -- TODO: Is this sound?
      Nothing -> error $ "Pointer "++show ptr++" couldn't be found for loading"
    | otherwise -> return ([],Nothing,[])
  MILoadPtr mfrom ptr_from ptr_to
    | mfrom==loc -> do
        let srcs = case Map.lookup ptr_from all_ptrs of
              Nothing -> []
              Just x -> x
            nptr = [ if obj_p==new_obj
                     then [ concat [ case Map.lookup p all_ptrs of
                                        Just dests -> [ (and' `app` [cond,cond',cond'',cond''',cond'''',cond'''''],dest)
                                                      | (cond''''',dest) <- dests ]
                                   | (p,cond'''') <- validPointers loaded' ] ++
                            [ (and' `app` [cond,cond',cond'',cond''',cond''''],NullPointer) | cond'''' <- nullPointers loaded' ]
                          | (cond'',obj) <- new_conds
                          , let ObjAccessor access = ptrIndexGetAccessor structs idx
                                (_,loaded,errs) = access
                                                  (\obj' -> let (res,errs) = loadPtr obj'
                                                            in (obj',[(res,constant True)],errs)
                                                  ) obj
                          , (loaded',cond''') <- loaded
                          ]
                     else []
                   | (cond,src) <- srcs,
                     ((obj_p,idx),cond') <- validPointers src
                   ]
        return ([],case concat $ concat nptr of
                   [] -> Nothing
                   xs -> Just (ptr_to,xs),[])
    | otherwise -> return ([],Nothing,[])
  MIStore mfrom val ptr mto
    | mfrom==loc -> case Map.lookup ptr all_ptrs of
      Just trgs -> do
        let res = [(mto,new_obj,concat
                                [ if obj_p==new_obj
                                  then [ ([((not' $ cond .&&. cond') .&&. cond'',obj)
                                          ,(app and' [cond,cond',cond''],nobj)],[ (desc,app and' [act,cond,cond',cond'',cond''']) | (desc,cond''') <- errs ])
                                       | (cond'',obj) <- new_conds
                                       , let (nobj,_,errs) = access (\obj' -> let (res,errs) = storeObject val obj'
                                                                              in (res,[((),constant True)],errs)
                                                                    ) obj
                                       ]
                                  else [ ([(app and' [cond,cond',cond''],obj)],[]) | (cond'',obj) <- new_conds ]
                                | (cond,p) <- trgs
                                , ((obj_p,idx),cond') <- validPointers p
                                , let ObjAccessor access = ptrIndexGetAccessor structs idx ])]
        return ([ (mto,new_obj,concat [ upd | (upd,_) <- upds ]) | (mto,new_obj,upds) <- res ],Nothing,
                concat [ errs | (_,_,upds) <- res, (_,errs) <- upds ])
      Nothing -> return ([(mto,new_obj,new_conds)],Nothing,[])
    | otherwise -> return ([],Nothing,[])
  MIStorePtr mfrom ptr_from ptr_to mto
    | mfrom==loc -> case Map.lookup ptr_to all_ptrs of
      Just trgs -> return
                   ([(mto,new_obj,concat
                                  [ if obj_p==new_obj
                                    then concat
                                         [ [((not' $ cond .&&. cond') .&&. cond'',obj)
                                           ,(app and' [cond,cond',cond''],nobj)]
                                         | (cond'',obj) <- new_conds
                                         , let (nobj,_,errs) = access (\obj' -> let (res,errs) = storePtr (ValidPointer ptr_from) obj'
                                                                                in (res,[((),constant True)],errs)
                                                                      ) obj
                                         ]
                                    else [ (app and' [cond,cond',cond''],obj) | (cond'',obj) <- new_conds ]
                                  | (cond,p) <- trgs
                                  , ((obj_p,idx),cond') <- validPointers p
                                  , let ObjAccessor access = ptrIndexGetAccessor structs idx ])],Nothing,[])
      Nothing -> return ([(mto,new_obj,new_conds)],Nothing,[])
    | otherwise -> return ([],Nothing,[])
  MIPhi inc mto -> case List.find (\(_,mfrom) -> mfrom==loc) inc of
    Nothing -> return ([],Nothing,[])
    Just (cond,_) -> return ([(mto,new_obj,[ (cond' .&&. cond,obj) | (cond',obj) <-  new_conds ])],Nothing,[])
  _ -> case memInstrSrc instr of
    Nothing -> return ([],Nothing,[])
    Just sloc -> if sloc==loc
                 then (case memInstrTrg instr of
                          Nothing -> return ([],Nothing,[])
                          Just trg -> return ([(trg,new_obj,new_conds)],Nothing,[]))
                 else return ([],Nothing,[])

snowDebugLocation :: Show ptr => String -> SnowLocation ptr -> [String]
snowDebugLocation loc_name cont
  = listHeader (loc_name++":") $
    ["Objects"]++
    (concat [ listHeader ("  "++show obj_p++":")
              [ show cond++" ~> "++show obj'
              | (cond,obj') <- obj ]
            | (obj_p,obj) <- Map.toList (snowObjects cont) ])

listHeader :: String -> [String] -> [String]
listHeader x [] = []
listHeader x (y:ys) = let l = (length x)+1
                      in (x++" "++y):(fmap ((replicate l ' ')++) ys)

snowDebug :: (Show ptr,Show mloc) => SnowMemory mloc ptr -> String
snowDebug mem = unlines $
                (snowDebugLocation "Global" (snowGlobal mem))++
                (concat
                 [ snowDebugLocation (show loc) cont
                 | (loc,cont) <- Map.toList (snowLocations mem)
                 ])++
                (listHeader "Pointers:"
                 [ concat $
                   listHeader (show ptr++":")
                   [ show cond ++ " ~> " ++ (case obj of
                                                NullPointer -> "null"
                                                ValidPointer (obj_p,idx) -> show obj_p++show idx)
                   | (cond,obj) <- assigns ]
                 | (ptr,assigns) <- Map.toList (snowPointers mem) ])++
                (listHeader "Pointer connects:"
                 [ concat $
                   listHeader (show ptr++":")
                   [ show cond ++ " ~> " ++ show oth
                   | (oth,cond) <- conns ]
                 | (ptr,conns) <- Map.toList (snowPointerConnections mem)
                 ])
