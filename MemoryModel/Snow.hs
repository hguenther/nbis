{-# LANGUAGE FlexibleInstances,MultiParamTypeClasses,GADTs,RankNTypes #-}
module MemoryModel.Snow where

import MemoryModel
import DecisionTree
import TypeDesc

import Language.SMTLib2
--import qualified Data.Graph.Inductive as Gr
import Data.Map as Map hiding (foldl)
import Data.Foldable
import Data.Traversable
import Prelude hiding (foldl1,foldl,mapM_,concat,mapM)
import Data.Bits
import Control.Monad.Trans
import Data.Maybe (catMaybes)

import MemoryModel.Snow.Object

type BVPtr = BV64
type BVByte = BitVector BVUntyped

data SnowMemory ptr = SnowMemory { snowStructs :: Map String [TypeDesc]
                                 , snowLocs :: Map Int (MemoryProgram ptr)
                                 , snowPointer :: Map ptr (DecisionTree (Maybe (Integer,PtrIndex)))
                                 , snowObjects :: Map Integer (Object ptr)
                                 , snowGlobals :: Map ptr (Integer,TypeDesc)
                                 , snowNextObject :: Integer
                                 }

instance (Ord ptr,Show ptr) => MemoryModel (SnowMemory ptr) ptr where
  memNew _ _ structs = return $ SnowMemory structs Map.empty Map.empty Map.empty Map.empty 0
  addGlobal mem ptr tp cont = do
    glb <- mkGlobal cont
    return $ mem { snowGlobals = Map.insert ptr (snowNextObject mem,tp) (snowGlobals mem)
                 , snowObjects = Map.insert (snowNextObject mem) glb (snowObjects mem)
                 , snowNextObject = succ (snowNextObject mem)
                 }
  addProgram mem loc prog
    = do
      liftIO $ do
        putStrLn $ "New program for "++show loc++":"
        mapM_ print prog
      (ptrs,objs,next) <- initialObjects (snowStructs mem) (snowNextObject mem) prog
      return $ mem { snowLocs = Map.insert loc prog (snowLocs mem)
                   , snowPointer = Map.union ptrs (snowPointer mem)
                   , snowObjects = Map.union objs (snowObjects mem)
                   , snowNextObject = next
                   }
  connectPrograms mem cond from to ptrs = do
    liftIO $ do
      putStrLn $ "Connect location "++show from++" with "++show to
      putStrLn $ show ptrs
    let prog_to = (snowLocs mem)!to
        ptr1 = foldl (\cptr (ptr_to,ptr_from) -> Map.insert ptr_to (cptr!ptr_from) cptr
                     ) (snowPointer mem) ptrs
        ptr2 = Map.union ptr1 (fmap (\(i,tp) -> decision (Just (i,[(tp,[])]))) (snowGlobals mem))
    (new_ptr,new_objs,next') <- updateLocation (snowStructs mem) cond ptr2 (snowObjects mem) (snowNextObject mem) prog_to
    let nmem = mem { snowPointer = new_ptr
                   , snowObjects = new_objs
                   , snowNextObject = next'
                   }
    return nmem

initialObjects :: Ord ptr => Map String [TypeDesc]
                  -> Integer
                  -> [MemoryInstruction ptr]
                  -> SMT (Map ptr (DecisionTree (Maybe (Integer,PtrIndex))),
                          Map Integer (Object ptr),
                          Integer)
initialObjects structs n
  = foldlM (\(ptrs,objs,next) instr -> case instr of
               MINull tp p -> return (Map.insert p (decision Nothing) ptrs,
                                      objs,
                                      next)
               MIAlloc tp sz p -> do
                 obj <- allocaObject structs tp sz
                 return (Map.insert p (decision (Just (next,[(tp,[])]))) ptrs,
                         Map.insert next obj objs,
                         succ next)
               _ -> return (ptrs,objs,next)
           ) (Map.empty,Map.empty,n)

updateLocation :: (Ord ptr,Show ptr) => Map String [TypeDesc] 
                  -> SMTExpr Bool 
                  -> Map ptr (DecisionTree (Maybe (Integer,PtrIndex)))
                  -> Map Integer (Object ptr)
                  -> Integer
                  -> [MemoryInstruction ptr] 
                  -> SMT (Map ptr (DecisionTree (Maybe (Integer,PtrIndex))),
                          Map Integer (Object ptr),
                          Integer)
updateLocation structs cond ptrs objs next
  = foldlM (\(ptrs,objs,next) instr -> case instr of
               -- Allocations don't have to be updated
               MIAlloc _ _ _ -> return (ptrs,objs,next)
               -- Neither do null pointers
               MINull _ _ -> return (ptrs,objs,next)
               MILoad ptr res -> case Map.lookup ptr ptrs of
                 Just dt -> do
                   let sz = extractAnnotation res
                       obj' = fst $ accumDecisionTree
                              (\cond' p
                                -> case p of
                                 Nothing -> (constantAnn (BitVector 0) (extractAnnotation res),[(NullDeref,cond')])
                                 Just (obj_p,idx)
                                   -> case Map.lookup obj_p objs of
                                   Just obj -> let ObjAccessor access = ptrIndexGetAccessor structs idx
                                                   (_,res,errs) = access (\obj' -> let (res,errs) = loadObject sz obj'
                                                                                   in (obj',res,errs)
                                                                         ) obj
                                               in (res,errs)
                              ) dt
                   assert $ cond .=>. (res .==. obj')
                   return (ptrs,objs,next)
               MILoadPtr from to -> case Map.lookup from ptrs of
                 Just dt -> do
                   let (errs,ndt) = traverseDecisionTree
                                    (\c p -> case p of
                                        Nothing -> ([(NullDeref,c)],decision Nothing)
                                        Just (obj_p,idx) -> let Just obj = Map.lookup obj_p objs
                                                                ObjAccessor access = ptrIndexGetAccessor structs idx
                                                                PointerType tp = ptrIndexGetType structs idx
                                                                (_,ptr,errs) = access (\obj' -> let (res,errs) = loadPtr obj'
                                                                                                in (obj',res,errs)
                                                                                      ) obj
                                                            in (errs,case ptr of
                                                                   Nothing -> decision Nothing
                                                                   Just ptr' -> let Just dt' = Map.lookup ptr' ptrs
                                                                                in dt')
                                    ) dt
                   return (Map.insert to ndt ptrs,objs,next)
               MIStore val ptr -> case Map.lookup ptr ptrs of
                 Just dt -> do
                   let (nnext,nobjs,ups)
                         = foldl (\(cnext,cobjs,cups) (Just (obj_p,idx))
                                  -> case Map.lookup obj_p objs of
                                    Just obj -> let ObjAccessor access = ptrIndexGetAccessor structs idx
                                                    (nobj,_,_) = access (\obj' -> let (nobj',errs') = storeObject val obj'
                                                                                 in (nobj',(),errs')
                                                                        ) obj
                                                in (succ cnext,
                                                    Map.insert cnext nobj cobjs,
                                                    Map.insert obj_p cnext cups)
                                 ) (next,objs,Map.empty) dt
                       nptrs = fmap (fmap (fmap (\(obj_p,idx) -> case Map.lookup obj_p ups of
                                                    Nothing -> (obj_p,idx)
                                                    Just nobj_p -> (nobj_p,idx)
                                                )
                                          )
                                    ) ptrs
                   return (nptrs,nobjs,nnext)
               MIStorePtr ptr trg -> case Map.lookup trg ptrs of
                 Just dt -> do
                   let (nnext,nobjs,ups)
                         = foldl (\(cnext,cobjs,cups) (Just (obj_p,idx))
                                  -> case Map.lookup obj_p objs of
                                    Just obj -> let ObjAccessor access = ptrIndexGetAccessor structs idx
                                                    (nobj,_,_) = access (\obj' -> let (nobj',errs') = storePtr ptr obj'
                                                                                 in (nobj',(),errs')
                                                                        ) obj
                                                in (succ cnext,
                                                    Map.insert cnext nobj cobjs,
                                                    Map.insert obj_p cnext cups)
                                 ) (next,objs,Map.empty) dt
                       nptrs = fmap (fmap (fmap (\(obj_p,idx) -> case Map.lookup obj_p ups of
                                                    Nothing -> (obj_p,idx)
                                                    Just nobj_p -> (nobj_p,idx)
                                                )
                                          )
                                    ) ptrs
                   return (nptrs,nobjs,nnext)
               MICast from to ptr_from ptr_to -> case Map.lookup ptr_from ptrs of
                 Just dt -> do
                   let ndt = fmap (fmap (\(obj_p,idx) -> (obj_p,ptrIndexCast structs to idx))) dt
                   return (Map.insert ptr_to ndt ptrs,objs,next)
               MIIndex idx ptr_from ptr_to -> case Map.lookup ptr_from ptrs of
                 Just dt -> do
                   let ndt = fmap (fmap (\(obj_p,idx') -> (obj_p,ptrIndexIndex idx idx'))) dt
                   return (Map.insert ptr_to ndt ptrs,objs,next)
               MISelect opts ptr
                 -> return (Map.insert ptr (caseDecision Nothing (catMaybes [ do
                                                                                 dt <- Map.lookup ptr' ptrs
                                                                                 return (cond,dt)
                                                                            | (cond,ptr') <- opts ])) ptrs,
                            objs,next)
               MICompare ptr1 ptr2 cmp_res -> do
                 let Just dt1 = Map.lookup ptr1 ptrs
                     Just dt2 = Map.lookup ptr2 ptrs
                     res = decisionTreeEq (\p1 p2 -> case p1 of
                                              Nothing -> case p2 of
                                                Just _ -> Left False
                                                Nothing -> Left True
                                              Just (obj1,idx1) -> case p2 of
                                                Nothing -> Left False
                                                Just (obj2,idx2) -> if obj1/=obj2
                                                                    then Left False
                                                                    else ptrIndexEq idx1 idx2) dt1 dt2
                 assert $ cmp_res .==. res
                 return (ptrs,objs,next)
               _ -> error $ "Memory instruction "++show instr++" not implemented in Snow memory model."
           ) (ptrs,objs,next)

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

snowDebug :: Show ptr => SnowMemory ptr -> String
snowDebug snow = unlines $
                 ["Objects: "]++
                 ["  "++show i++": "++show obj | (i,obj) <- Map.toList (snowObjects snow)]++
                 ["Pointers: "]++
                 ["  "++show ptr++": "++show (decisionTreeElems dt)
                 | (ptr,dt) <- Map.toList (snowPointer snow)]
