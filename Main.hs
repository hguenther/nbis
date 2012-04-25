{-# LANGUAGE DeriveDataTypeable,TypeFamilies,FlexibleContexts,RankNTypes,OverloadedStrings #-}
module Main where

import MemoryModel
import MemoryModel.Untyped
import MemoryModel.UntypedBlocks
import MemoryModel.Typed
import Language.SMTLib2
import Language.SMTLib2.Internals
import Data.Typeable
import Control.Monad.Trans
import System.Environment (getArgs)
import Data.List (genericLength,genericReplicate,genericSplitAt,zip4,zipWith4,zipWith5)
import Data.Map as Map hiding (foldl,foldr,(!),mapMaybe)
import Data.Set as Set hiding (foldl,foldr)
import qualified Data.Bitstream as BitS
import LLVM.Core
import qualified LLVM.FFI.Core as FFI
import Debug.Trace
import Prelude hiding (foldl,concat,mapM_,any,foldr,mapM,foldl1)
import Data.Foldable
import Data.Traversable
import System.Console.GetOpt
import System.Exit
import Control.Monad (when)
import Data.Maybe (mapMaybe,maybeToList)
import Data.Bits as Bits
type Watchpoint = (String,SMTExpr Bool,[(TypeDesc,SMTExpr BitVector)])

(!) :: (Show k,Ord k) => Map k a -> k -> a
(!) mp k = case Map.lookup k mp of
             Nothing -> error $ "Couldn't find key "++show k++" in "++show (Map.keys mp)
             Just r -> r

data Val m = ConstValue { asConst :: BitVector }
           | DirectValue { asValue :: SMTExpr BitVector }
           | PointerValue { asPointer :: Pointer m }
           | ConditionValue { asCondition :: SMTExpr Bool }
           | ConstCondition { asConstCondition :: Bool }
             deriving (Typeable)

instance Show (Val m) where
  show (ConstValue c) = show c
  show (DirectValue dv) = show dv
  show (PointerValue _) = "<pointer>"
  show (ConditionValue c) = show c

instance MemoryModel m => Eq (Val m) where
    (ConstValue x) == (ConstValue y) = x == y
    (DirectValue x) == (DirectValue y) = x == y
    (PointerValue x) == (PointerValue y) = x == y
    (ConditionValue x) == (ConditionValue y) = x == y
    (ConstCondition x) == (ConstCondition y) = x == y
    _ == _ = False

valEq :: MemoryModel m => m -> Val m -> Val m -> SMTExpr Bool
valEq mem (ConstValue x) (ConstValue y) = if x==y then constant True else constant False
valEq mem (ConstValue x) (DirectValue y) = y .==. constantAnn x (BitS.length x)
valEq mem (DirectValue x) (ConstValue y) = x .==. constantAnn y (BitS.length y)
valEq mem (DirectValue v1) (DirectValue v2) = v1 .==. v2
valEq mem (PointerValue p1) (PointerValue p2) = memPtrEq mem p1 p2
valEq mem (ConditionValue v1) (ConditionValue v2) = v1 .==. v2
valEq mem (ConditionValue v1) (ConstValue v2) = if v2 == BitS.pack [True]
                                                then v1
                                                else not' v1
valEq mem (ConstValue v1) (ConditionValue v2) = if v1 == BitS.pack [True]
                                                then v2
                                                else not' v2
valEq mem (ConditionValue v1) (DirectValue v2) = v1 .==. (v2 .==. (constantAnn (BitS.pack [True]) 1))
valEq mem (DirectValue v2) (ConditionValue v1) = v1 .==. (v2 .==. (constantAnn (BitS.pack [True]) 1))
valEq mem (ConstCondition x) (ConstCondition y) = constant (x == y)
valEq mem (ConstCondition x) (ConditionValue y) = if x then y else not' y
valEq mem (ConditionValue x) (ConstCondition y) = if y then x else not' x

valSwitch :: MemoryModel m => m -> TypeDesc -> [(Val m,SMTExpr Bool)] -> SMT (Val m)
valSwitch mem _ [(val,_)] = return val
valSwitch mem (TDPtr _) choices = do
  res <- memPtrSwitch mem [ (ptr,cond) | (PointerValue ptr,cond) <- choices ]
  return $ PointerValue res
valSwitch mem tp choices = return $ DirectValue $ mkSwitch choices
  where
    mkSwitch [(val,cond)] = valValue val
    mkSwitch ((val,cond):rest) = ite cond (valValue val) (mkSwitch rest)

valCond :: Val m -> SMTExpr Bool
valCond (ConstValue x) = case BitS.unpack x of
  [x'] -> constant x'
  _ -> error "A constant of bit-length > 1 is used in a condition"
valCond (DirectValue x) = x .==. (constantAnn (BitS.pack [True]) 1)
valCond (ConditionValue x) = x
valCond (ConstCondition x) = constant x

valValue :: Val m -> SMTExpr BitVector
valValue (ConstValue x) = constantAnn x (BitS.length x)
valValue (DirectValue x) = x
valValue (ConditionValue x) = ite x (constantAnn (BitS.pack [True]) 1) (constantAnn (BitS.pack [False]) 1)
valValue (ConstCondition x) = constantAnn (BitS.pack [x]) 1

newValue :: MemoryModel mem => mem -> TypeDesc -> SMT (Val mem)
newValue mem (TDPtr tp) = do
  ptr <- memPtrNew mem tp
  return (PointerValue ptr)
newValue _ tp = do
  v <- varAnn (fromIntegral $ bitWidth tp)
  return (DirectValue v)

data RealizedBlock m = RealizedBlock { rblockActivation :: SMTExpr Bool
                                     , rblockMemoryOut  :: m
                                     , rblockOutput     :: Map String (Val m)
                                     , rblockJumps      :: Map String (SMTExpr Bool)
                                     , rblockReturns    :: Maybe (Maybe (Val m))
                                     }

translateProgram :: (MemoryModel mem) 
                    => Map String ([(String,TypeDesc)],TypeDesc,[(String,[(String,InstrDesc)])]) -> String -> Integer -> SMT (mem,mem,[Watchpoint])
translateProgram program entry_point limit = do
  let alltps = foldl (\tps (args,rtp,blocks) 
                      -> let tpsArgs = allTypesArgs args
                             tpsBlocks = allTypesBlks blocks
                         in tps++tpsArgs++tpsBlocks) [] program
      (args,rtp,blks) = program!entry_point
  (arg_vals,mem_in) <- prepareEnvironment alltps args
  (mem_out,ret,watches) <- translateFunction alltps program entry_point args rtp blks limit (constant True) mem_in (zip arg_vals (fmap snd args))
  return (mem_in,mem_out,watches)

translateFunction :: (MemoryModel m)
                     => [TypeDesc]
                     -> Map String ([(String,TypeDesc)],TypeDesc,[(String,[(String,InstrDesc)])])
                     -> String
                     -> [(String,TypeDesc)] -> TypeDesc
                     -> [(String,[(String,InstrDesc)])]
                     -> Integer
                     -> SMTExpr Bool
                     -> m
                     -> [(Val m,TypeDesc)]
                     -> SMT (m,Maybe (Val m),[Watchpoint])
translateFunction allTps program fname argTps tp blocks limit act mem_in args
  = do
    let blockMp = mkVarBlockMap (fmap fst argTps) blocks
        blockSigs = mkBlockSigs blockMp blocks
        ordMp = Map.fromList (zipWith (\(name,instrs) n -> (name,(instrs,n))) (("",[]):blocks) [0..])
        infoMp = Map.intersectionWith (\(instrs,n) sig -> (instrs,n,sig)) ordMp blockSigs
        inps = zipWith (\(name,_) (arg,_) -> (name,arg)) argTps args
    bfs allTps infoMp (Map.singleton ("",0) (RealizedBlock { rblockActivation = act
                                                           , rblockMemoryOut = mem_in
                                                           , rblockOutput = Map.fromList inps
                                                           , rblockJumps = Map.singleton (fst $ head blocks) (constant True)
                                                           , rblockReturns = Nothing 
                                                           }))
      [] [(fst $ head blocks,0,1)]
  where
    bfs _ _ done watch [] = do
      rmem <- memSwitch [ (mem,act) | RealizedBlock { rblockReturns = Just _ 
                                                    , rblockMemoryOut = mem 
                                                    , rblockActivation = act } <- Map.elems done ]
      ret <- case tp of
        TDVoid -> return Nothing
        _ -> do
          ret' <- valSwitch rmem tp [ (val,act) | RealizedBlock { rblockReturns = Just (Just val)
                                                                , rblockActivation = act
                                                                } <- Map.elems done ]
          return $ Just ret'
      return (rmem,ret,watch)
    bfs tps info done watch (nxt@(name,lvl,_):rest)
      | Map.member (name,lvl) done = bfs tps info done watch rest
      | otherwise = do
        comment $ " Block "++fname++" -> "++name++" ("++show lvl++")"
        (nblk,watch') <- trans tps done (\f -> case intrinsics f of
                                            Nothing -> case Map.lookup f program of
                                              Nothing -> error $ "Function "++show f++" not found"
                                              Just (args,rtp,blocks) -> case blocks of
                                                [] -> error $ "Function "++f++" has no implementation"
                                                _ -> translateFunction allTps program f args rtp blocks (limit-lvl-1)
                                            Just intr -> intr
                                        ) fname info (name,lvl)
        let (_,lvl_cur,_) = case Map.lookup name info of
              Nothing -> error $ "Internal error: Failed to find block signature for "++name
              Just x -> x
            trgs = [ (trg,lvl',lvl_trg) 
                   | trg <- Map.keys $ rblockJumps nblk,
                     let (_,lvl_trg,_) = info!trg,let lvl' = if lvl_cur < lvl_trg then lvl else lvl+1,lvl' < limit ]
        bfs tps info (Map.insert (name,lvl) nblk done) (watch++watch') (foldl insert' rest trgs)
    
    insert' [] it = [it]
    insert' all@((cname,clvl,cord):rest) (name,lvl,ord)
      | clvl > lvl || (clvl==lvl && cord > ord) = (name,lvl,ord):all
      | otherwise = (cname,clvl,cord):(insert' rest (name,lvl,ord))
                         
trans :: (MemoryModel m) 
         => [TypeDesc] -> Map (String,Integer) (RealizedBlock m) 
         -> (String -> SMTExpr Bool -> m -> [(Val m,TypeDesc)] -> SMT (m,Maybe (Val m),[Watchpoint]))
         -> String
         -> Map String ([(String,InstrDesc)],Integer,BlockSig)
         -> (String,Integer) 
         -> SMT (RealizedBlock m,[Watchpoint])
trans tps acts calls fname blocks (name,lvl) = do
    let (instrs,ord,sig) = blocks!name
        froms = [ (rblockActivation realized,rblockMemoryOut realized,(rblockJumps realized)!name)
                | from <- Set.toList (blockOrigins sig), 
                  let (_,ord_from,sig_from) = blocks!from,
                  let lvl_from = if ord_from < ord
                                 then lvl
                                 else lvl-1,
                  lvl_from >= 0, 
                  realized <- maybeToList (Map.lookup (from,lvl_from) acts) ]
    act <- var
    assert $ act .==. or' [ and' [act',cond] | (act',_,cond) <- froms ]
    mem <- case froms of
             [] -> do
               mem <- memNew tps
               assert $ memInit mem
               return mem
             conds -> memSwitch [ (mem,and' [act',cond])  | (act',mem,cond) <- conds ]
    inps <- mapM (\(from,tp) -> case from of
                        [(blk,Left (blk',var))] -> case Map.lookup (blk',lvl) acts of
                          Nothing -> return $ (rblockOutput (acts!(blk',0)))!var
                          Just inp_mp -> return $ (rblockOutput inp_mp)!var
                        _ -> do
                          let choices = mapMaybe (\(blk,arg) -> let (_,ord_from,_) = blocks!blk
                                                                    lvl_from = if ord_from < ord
                                                                               then lvl
                                                                               else lvl-1
                                                                in if lvl_from < 0
                                                                   then Nothing
                                                                   else (case Map.lookup (blk,lvl_from) acts of
                                                                            Nothing -> Nothing
                                                                            Just realized_from -> Just (case arg of
                                                                                                           Left (blk',var) -> (rblockOutput $ acts!(blk',lvl_from))!var
                                                                                                           Right bv -> ConstValue bv,
                                                                                                        and' [rblockActivation realized_from,(rblockJumps realized_from)!name]))
                                                 ) from
                          valSwitch mem tp choices
                 ) (blockInputs sig)
    (nmem,outps,ret',jumps,watch) <- realizeBlock fname instrs act mem False inps calls (\lbl instr -> return () {- comment $ " "++lbl++": "++show instr -}) []
    jumps' <- translateJumps jumps
    return $ (RealizedBlock { rblockActivation = act
                            , rblockMemoryOut = case nmem of
                              Nothing -> mem
                              Just nmem' -> nmem'
                            , rblockOutput = outps
                            , rblockJumps = jumps'
                            , rblockReturns = ret'
                            },watch)

translateJumps :: [(String,Maybe (SMTExpr Bool))] -> SMT (Map String (SMTExpr Bool))
translateJumps = translateJumps' []
  where
    translateJumps' [] [(from,Nothing)] = return $ Map.singleton from (constant True)
    translateJumps' _ [] = return Map.empty
    translateJumps' pre ((from,cond):rest) = do
      (npre,rcond) <- case cond of
        Nothing -> return (pre,case pre of
                              [] -> constant True
                              _ -> and' $ fmap not' pre)
        Just cond' -> do
          v <- var
          assert $ v .==. cond'
          return (v:pre,case pre of
                     [] -> v
                     _ -> and' (v:(fmap not' pre)))
      mp <- translateJumps' npre rest
      return $ Map.insert from rcond mp
        
showBlockSig :: String -> BlockSig -> [String]
showBlockSig name sig 
  = name:"  inputs":
    (concat [ ("    "++iname++" : "++show itp): 
              [ "    "++(fmap (const ' ') iname)++" | "++ 
                (case inf of 
                    Left (fblk,fvar) -> fblk++"."++fvar
                    Right bv -> show bv)
              | (from,inf) <- ifrom
              ] | (iname,(ifrom,itp)) <- Map.toList (blockInputs sig) ]) ++
    "  outputs":[ "    "++oname++" : "++show otp | (oname,otp) <- Map.toList (blockOutputs sig) ] ++
    "  calls":[ "    "++cname++" : "++concat [ show atp++" -> " | atp <- args ]++show tp | (cname,(args,tp)) <- Map.toList (blockCalls sig) ] ++
    "  jumps":[ "    "++trg | trg <- Set.toList (blockJumps sig) ] ++
    "  origins":[ "    "++src | src <- Set.toList (blockOrigins sig) ]

data BlockSig = BlockSig
    { blockInputs  :: Map String ([(String,Either (String,String) BitVector)],TypeDesc)
    , blockOutputs :: Map String TypeDesc
    , blockCalls   :: Map String ([TypeDesc],TypeDesc)
    , blockJumps   :: Set String
    , blockOrigins :: Set String
    } deriving Show

emptyBlockSig :: BlockSig
emptyBlockSig = BlockSig { blockInputs = Map.empty
                         , blockOutputs = Map.empty
                         , blockCalls = Map.empty
                         , blockJumps = Set.empty
                         , blockOrigins = Set.empty }

realizeBlock :: MemoryModel mem => String -> [(String,InstrDesc)] 
                -> SMTExpr Bool
                -> mem
                -> Bool
                -> Map String (Val mem) 
                -> (String -> SMTExpr Bool -> mem -> [(Val mem,TypeDesc)] -> SMT (mem,Maybe (Val mem),[Watchpoint]))
                -> (String -> InstrDesc -> SMT ())
                -> [Watchpoint]
                -> SMT (Maybe mem,Map String (Val mem),Maybe (Maybe (Val mem)),[(String,Maybe (SMTExpr Bool))],[Watchpoint])
realizeBlock fname ((lbl,instr):instrs) act mem changed values calls debug watch
    = do
      debug lbl instr
      (nmem,nvalue,ret,jumps,watch') <- realizeInstruction fname lbl instr act mem values calls
      let values' = case nvalue of
            Nothing -> values
            Just res -> Map.insert lbl res values
          (mem',changed') = case nmem of
            Nothing -> (mem,changed)
            Just n -> (n,True)
      case ret of
        Just ret' -> return (if changed then Just mem' else Nothing,values',ret,jumps,watch++watch')
        Nothing -> case jumps of
          _:_ -> return (if changed then Just mem' else Nothing,values',ret,jumps,watch++watch')
          [] -> realizeBlock fname instrs act mem' changed' values' calls debug (watch ++ watch')

realizeInstruction :: MemoryModel mem => String -> String -> InstrDesc 
                      -> SMTExpr Bool
                      -> mem 
                      -> Map String (Val mem) 
                      -> (String -> SMTExpr Bool -> mem -> [(Val mem,TypeDesc)] -> SMT (mem,Maybe (Val mem),[Watchpoint]))
                      -> SMT (Maybe mem,Maybe (Val mem),Maybe (Maybe (Val mem)),[(String,Maybe (SMTExpr Bool))],[Watchpoint])
realizeInstruction fname lbl instr act mem values calls
  = {-trace ("Realizing ("++lbl++") "++show instr++"..") $-} case instr of
      IDRet tp arg -> return (Nothing,Nothing,Just (Just (argToExpr tp arg values)),[],[])
      IDRetVoid -> return (Nothing,Nothing,Just Nothing,[],[])
      IDBrCond cond (AL ifT) (AL ifF) -> case argToExpr (TDInt False 1) cond values of
        ConstCondition cond' -> return (Nothing,Nothing,Nothing,[(if cond' then ifT else ifF,Nothing)],[])
        cond' -> return (Nothing,Nothing,Nothing,[(ifT,Just $ valCond cond'),(ifF,Nothing)],[])
      IDBrUncond (AL to) -> return (Nothing,Nothing,Nothing,[(to,Nothing)],[])
      IDSwitch tp ((val,AL def):args) -> case argToExpr tp val values of
        ConstValue v -> case [ to | (cmp_v,AL to) <- args, let ConstValue v' = argToExpr tp cmp_v values, v' == v ] of
          [] -> return (Nothing,Nothing,Nothing,[(def,Nothing)],[])
          [to] -> return (Nothing,Nothing,Nothing,[(to,Nothing)],[])
        v -> return (Nothing,Nothing,Nothing,[ (to,Just $ valEq mem v (argToExpr tp cmp_v values))
                                             | (cmp_v,AL to) <- args
                                             ] ++ [ (def,Nothing) ],[])
      IDBinOp op tp lhs rhs -> let lhs' = argToExpr tp lhs values
                                   rhs' = argToExpr tp rhs values
                                   apply (ConstValue lhs) (ConstValue rhs) = let lhs' = BitS.toBits lhs :: Integer
                                                                                 rhs' = BitS.toBits rhs :: Integer
                                                                                 rop = case op of
                                                                                   BOXor -> Bits.xor
                                                                                   BOAdd -> (+)
                                                                                   BOAnd -> (.&.)
                                                                                   BOSub -> (-)
                                                                                   BOShL -> \x y -> shiftL x (fromIntegral y)
                                                                                   BOOr -> (.|.)
                                                                                 nvalue = ConstValue (BitS.fromNBits (BitS.length lhs) (rop lhs' rhs'))
                                                                             in return (Nothing,Just nvalue,Nothing,[],[])
                                   apply lhs rhs = let lhs' = valValue lhs
                                                       rhs' = valValue rhs
                                                       rop = case op of 
                                                         BOXor -> BVXor
                                                         BOAdd -> BVAdd
                                                         BOAnd -> BVAnd
                                                         BOSub -> BVSub
                                                         BOShL -> BVSHL
                                                         BOOr -> BVOr
                                                         _ -> error $ "unsupported operator: "++show op
                                                       nvalue = DirectValue (rop lhs' rhs')
                                                   in return (Nothing,Just nvalue,Nothing,[],[])
                               in apply lhs' rhs'
      IDAlloca tp _ _ -> do
        (ptr,mem') <- memAlloc False tp mem
        return (Just mem',Just (PointerValue ptr),Nothing,[],[])
      IDLoad tp arg -> let PointerValue ptr = argToExpr (TDPtr tp) arg values
                       in return (Nothing,Just (DirectValue $ memLoad tp ptr mem),Nothing,[],[])
      IDStore tp val to -> let PointerValue ptr = argToExpr (TDPtr tp) to values
                               val' = valValue $ argToExpr tp val values
                           in return (Just $ memStore tp ptr val' mem,Nothing,Nothing,[],[])
      IDGetElementPtr tp_to tp_from (arg:args) -> case argToExpr tp_from arg values of
        PointerValue ptr -> let ptr' = memIndex mem tp_from [ fromIntegral i | AI i <- args ] ptr
                            in return (Nothing,Just (PointerValue ptr'),Nothing,[],[])
        v -> error $ "First argument to getelementptr must be a pointer, but I found: "++show v++" ("++fname++")\n"++lbl++": "++show instr
      IDZExt tp tp' var -> let v = valValue $ argToExpr tp' var values
                               d = (bitWidth tp') - (bitWidth tp)
                               nv = bvconcat (constantAnn (BitS.fromNBits d (0::Integer) :: BitVector) (fromIntegral d)) v
                           in return (Nothing,Just (DirectValue nv),Nothing,[],[])
      IDBitcast (TDPtr tp) (TDPtr tp') arg -> let PointerValue ptr = argToExpr (TDPtr tp') arg values
                                                  nptr = memCast mem tp ptr
                                              in return (Nothing,Just (PointerValue nptr),Nothing,[],[])
      IDICmp pred tp lhs rhs -> let lhs' = argToExpr tp lhs values
                                    rhs' = argToExpr tp rhs values
                                    apply (ConstValue lhs) (ConstValue rhs) = let lhs' = BitS.toBits lhs :: Integer
                                                                                  rhs' = BitS.toBits rhs :: Integer
                                                                                  op = case pred of
                                                                                    IntEQ -> (==)
                                                                                    IntNE -> (/=)
                                                                                    IntUGT -> (>)
                                                                                    IntUGE -> (>=)
                                                                                    IntULT -> (<)
                                                                                    IntULE -> (<=)
                                                                                    IntSGT -> (>)
                                                                                    IntSGE -> (>=)
                                                                                    IntSLT -> (<)
                                                                                    IntSLE -> (<=)
                                                                              in return (Nothing,Just (ConstCondition (op lhs' rhs')),Nothing,[],[])
                                    apply lhs rhs = let lhs' = valValue lhs
                                                        rhs' = valValue rhs
                                                        op = case pred of
                                                          IntEQ -> (.==.)
                                                          IntNE -> \x y -> not' $ x .==. y
                                                          IntUGT -> BVUGT
                                                          IntUGE -> BVUGE
                                                          IntULT -> BVULT
                                                          IntULE -> BVULE
                                                          IntSGT -> BVSGT
                                                          IntSGE -> BVSGE
                                                          IntSLT -> BVSLT
                                                          IntSLE -> BVSLE
                                                    in return (Nothing,Just (ConditionValue (op lhs' rhs')),Nothing,[],[])
                                in apply lhs' rhs'
      IDPhi _ _ -> return (Nothing,Nothing,Nothing,[],[])
      IDCall _ (AFP fn) args -> do
        (mem',ret,watch) <- calls fn act mem [ (argToExpr tp arg values,tp) | (arg,tp) <- args ]
        return (Just mem',ret,Nothing,[],watch)
      IDSelect tp cond ifT ifF -> let res = case argToExpr (TDInt False 1) cond values of
                                        ConstCondition c -> if c 
                                                            then argToExpr tp ifT values
                                                            else argToExpr tp ifF values
                                        cond' -> DirectValue $ ite 
                                                 (valCond cond') 
                                                 (valValue $ argToExpr tp ifT values) 
                                                 (valValue $ argToExpr tp ifF values)
                                  in return (Nothing,Just res,Nothing,[],[])
      IDTrunc tp_from tp_to arg -> return (Nothing,Just (case argToExpr tp_from arg values of
                                                            ConstValue bv -> ConstValue (BitS.fromNBits (bitWidth tp_to) (BitS.toBits bv :: Integer))
                                                            expr -> DirectValue (bvextract (bitWidth tp_to - 1) 0 (valValue expr))),Nothing,[],[])
      _ -> error $ "Unsupported instruction: "++show instr
    where
      argToExpr :: TypeDesc -> ArgDesc -> Map String (Val m) -> Val m
      argToExpr _ (AV var) mp = case Map.lookup var mp of
                                  Just val -> val
                                  Nothing -> error $ "Failed to find variable "++show var
      argToExpr tp (AI i) _ = if bitWidth tp == 1
                              then ConstCondition (i /= 0)
                              else ConstValue $ BitS.fromNBits (bitWidth tp) i
      argToExpr tp AE mp = ConstValue $ BitS.fromNBits (bitWidth tp) (0::Integer)
      argToExpr tp arg _ = error $ "argToExpr unimplemented for "++show arg

      ncond :: MemoryModel m => Val m -> SMTExpr Bool
      ncond (ConstValue v) = case BitS.unpack v of
                                  [x] -> constant x 
      ncond (DirectValue v) = v .==. (constantAnn (BitS.pack [False]) 1)



mkVarBlockMap :: [String] -> [(String,[(String,InstrDesc)])] -> Map String String
mkVarBlockMap args = foldl (\mp (blk,instrs) 
                            -> foldl (\mp' (lbl,instr) 
                                      -> Map.insert lbl blk mp') mp instrs
                           ) (Map.fromList [(arg,"") | arg <- args])

mkBlockSigs :: Map String String -> [(String,[(String,InstrDesc)])] -> Map String BlockSig
mkBlockSigs lbl_mp blks
    = Map.adjust (\sig -> sig { blockOrigins = Set.singleton "" }) (fst $ head blks) $
      foldl (\mp (blk,instrs)
               -> foldl (\mp' (lbl,instr) 
                        -> case instr of
                          IDRet tp arg -> addArg blk arg tp mp'
                          IDBrCond arg (AL ifT) (AL ifF) -> addArg blk arg (TDInt False 1) $
                                                           addJump blk ifT $ addJump blk ifF mp'
                          IDBrUncond (AL to) -> addJump blk to mp'
                          IDSwitch tp ((what,AL def):cases) 
                            -> addArg blk what tp $ addJump blk def $ foldl (\cmp (_,AL to) -> addJump blk to cmp) mp' cases
                          IDBinOp _ tp lhs rhs -> addArg blk lhs tp $ addArg blk rhs tp mp'
                          IDLoad tp arg -> addArg blk arg tp mp'
                          IDStore tp arg trg -> addArg blk arg tp $ addArg blk trg (TDPtr tp) mp'
                          IDGetElementPtr _ tp (arg:_) -> addArg blk arg tp mp'
                          IDTrunc _ tp arg -> addArg blk arg tp mp'
                          IDZExt _ tp arg -> addArg blk arg tp mp'
                          IDSExt _ tp arg -> addArg blk arg tp mp'
                          IDFPtoUI _ tp arg -> addArg blk arg tp mp'
                          IDFPtoSI _ tp arg -> addArg blk arg tp mp'
                          IDUItoFP _ tp arg -> addArg blk arg tp mp'
                          IDSItoFP _ tp arg -> addArg blk arg tp mp'
                          IDFPTrunc _ tp arg -> addArg blk arg tp mp'
                          IDFPExt _ tp arg -> addArg blk arg tp mp'
                          IDPtrToInt _ tp arg -> addArg blk arg tp mp'
                          IDIntToPtr _ tp arg -> addArg blk arg tp mp'
                          IDBitcast _ tp arg -> addArg blk arg tp mp'
                          IDICmp _ tp lhs rhs -> addArg blk lhs tp $ addArg blk rhs tp mp'
                          IDFCmp _ tp lhs rhs -> addArg blk lhs tp $ addArg blk rhs tp mp'
                          IDPhi tp args -> let vec = foldr (\(val,AL from) lst -> case val of
                                                              AE -> lst
                                                              AV var -> (from,Left (lbl_mp!var,var)):lst
                                                              AI i -> (from,Right (BitS.fromNBits (bitWidth tp) i)):lst
                                                          ) [] args
                                               mp1 = foldl (\mp'' (blk',lbl') -> addOutput blk' lbl' tp mp'') mp' [ x | (from,Left x) <- vec ]
                                               mp2 = addInput blk lbl (vec,tp) mp1
                                          in mp2
                          IDCall rtp (AFP fn) args
                            -> addCall blk fn (fmap snd args) rtp $ foldl (\cmp (arg,tp) -> addArg blk arg tp cmp) mp' args
                          IDSelect tp expr lhs rhs -> addArg blk expr (TDInt False 1) $ addArg blk lhs tp $ addArg blk rhs tp mp'
                          _ -> mp'
                       ) (Map.insertWith (\n o -> o) blk emptyBlockSig mp) instrs
            ) (Map.singleton "" (emptyBlockSig { blockJumps = Set.singleton $ fst $ head blks })) blks
      where
        addArg blk arg tp = case arg of
                              AV var -> let blk_from = case Map.lookup var lbl_mp of
                                                         Nothing -> ""
                                                         Just b -> b
                                        in if blk_from==blk
                                           then id
                                           else addOutput blk_from var tp . addInput blk var ([(blk_from,Left (blk_from,var))],tp)
                              _ -> id
        addInput blk lbl args = Map.alter (\c -> case c of
                                                   Nothing -> Just (emptyBlockSig { blockInputs = Map.singleton lbl args })
                                                   Just blksig -> Just $ blksig { blockInputs = Map.insert lbl args (blockInputs blksig) }) blk
        addOutput blk lbl tp = Map.alter (\c -> case c of
                                             Nothing -> Just (emptyBlockSig { blockOutputs = Map.singleton lbl tp })
                                             Just blksig -> Just $ blksig { blockOutputs = Map.insert lbl tp (blockOutputs blksig) }) blk
        addCall blk fn argtps rtp = Map.alter (\c -> case c of
                                                       Nothing -> Just (emptyBlockSig { blockCalls = Map.singleton fn (argtps,rtp) })
                                                       Just blksig -> Just $ blksig { blockCalls = Map.insert fn (argtps,rtp) (blockCalls blksig) }) blk
        addJump blk to = Map.alter (\c -> case c of
                                            Nothing -> Just (emptyBlockSig { blockJumps = Set.singleton to })
                                            Just blksig -> Just $ blksig { blockJumps = Set.insert to (blockJumps blksig) }) blk .
                         Map.alter (\c -> case c of
                                       Nothing -> Just (emptyBlockSig { blockOrigins = Set.singleton blk })
                                       Just blksig -> Just $ blksig { blockOrigins = Set.insert blk (blockOrigins blksig) }) to

allTypesArgs :: [(String,TypeDesc)] -> [TypeDesc]
allTypesArgs = allTypes' []
    where
      allTypes' tps [] = tps
      allTypes' tps ((name,tp):vals) = case tp of
        TDPtr tp' -> allTypes' (tp':tps) vals
        _ -> allTypes' tps vals

allTypesBlks :: [(String,[(String,InstrDesc)])] -> [TypeDesc]
allTypesBlks = allTypes' [] []
    where
      allTypes' [] tps [] = tps
      allTypes' [] tps ((_,instrs):blks) = allTypes' instrs tps blks
      allTypes' ((_,i):is) tps blks = case i of
                                        IDLoad tp _ -> allTypes' is (tp:tps) blks
                                        IDAlloca tp _ _ -> allTypes' is (tp:tps) blks
                                        _ -> allTypes' is tps blks

intr_memcpy :: (MemoryModel mem,Monad m) => SMTExpr Bool -> mem -> [(Val mem,TypeDesc)] -> m (mem,Maybe (Val mem),[Watchpoint])
intr_memcpy _ mem [(PointerValue to,_),(PointerValue from,_),(ConstValue len,_),_,_]
  = return (memCopy (BitS.toBits len) to from mem,Nothing,[])

intr_memset :: (MemoryModel mem,Monad m) => SMTExpr Bool -> mem -> [(Val mem,TypeDesc)] -> m (mem,Maybe (Val mem),[Watchpoint])
intr_memset _ mem [(PointerValue dest,_),(val,_),(ConstValue len,_),_,_]
  = return (memSet (BitS.toBits len) (valValue val) dest mem,Nothing,[])

intr_restrict :: MemoryModel mem => SMTExpr Bool -> mem -> [(Val mem,TypeDesc)] -> SMT (mem,Maybe (Val mem),[Watchpoint])
intr_restrict act mem [(val,_)] = do
  assert $ act .=>. (not' $ valValue val .==. constantAnn (BitS.fromNBits (32::Int) (0::Integer)) 32)
  return (mem,Nothing,[])

intr_nondet :: MemoryModel mem => Integer -> SMTExpr Bool -> mem -> [(Val mem,TypeDesc)] -> SMT (mem,Maybe (Val mem),[Watchpoint])
intr_nondet width _ mem [] = do
  v <- varAnn (fromIntegral width)
  return (mem,Just (DirectValue v),[])

intr_watch :: MemoryModel mem => SMTExpr Bool -> mem -> [(Val mem,TypeDesc)] -> SMT (mem,Maybe (Val mem),[Watchpoint])
intr_watch act mem ((ConstValue num,_):exprs)
  = return (mem,Nothing,[(show (BitS.toBits num :: Integer),act,[ (tp,valValue val) | (val,tp) <- exprs ])])

intrinsics :: MemoryModel mem => String -> Maybe (SMTExpr Bool -> mem -> [(Val mem,TypeDesc)] -> SMT (mem,Maybe (Val mem),[Watchpoint]))
intrinsics "llvm.memcpy.p0i8.p0i8.i64" = Just intr_memcpy
intrinsics "llvm.memcpy.p0i8.p0i8.i32" = Just intr_memcpy
intrinsics "llvm.memset.p0i8.i32" = Just intr_memset
intrinsics "llvm.memset.p0i8.i64" = Just intr_memset
intrinsics "furchtbar_restrict" = Just intr_restrict
intrinsics "furchtbar_nondet_i64" = Just (intr_nondet 64)
intrinsics "furchtbar_nondet_i32" = Just (intr_nondet 32)
intrinsics "furchtbar_nondet_i16" = Just (intr_nondet 16)
intrinsics "furchtbar_nondet_i8" = Just (intr_nondet 8)
intrinsics "furchtbar_nondet_u64" = Just (intr_nondet 64)
intrinsics "furchtbar_nondet_u32" = Just (intr_nondet 32)
intrinsics "furchtbar_nondet_u16" = Just (intr_nondet 16)
intrinsics "furchtbar_nondet_u8" = Just (intr_nondet 8)
intrinsics "furchtbar_watch" = Just intr_watch
intrinsics _ = Nothing
                                                 
getProgram :: String -> IO (Map String ([(String,TypeDesc)],TypeDesc,[(String,[(String,InstrDesc)])]))
getProgram file = do
  m <- readBitcodeFromFile file
  funs <- getFunctions m
  res <- mapM (\(name,fun) -> do
                  pars <- liftIO $ getParams fun >>= mapM (\(name,ref) -> do
                                                              tp <- FFI.typeOf ref >>= typeDesc2
                                                              return (name,tp))
                  tp <- liftIO $ FFI.typeOf fun >>= FFI.getElementType >>= FFI.getReturnType >>= typeDesc2
                  blks <- liftIO $ getBasicBlocks fun >>= mapM (\(name,blk) -> do
                                                                   instrs <- getInstructions blk >>= mapM (\(name,instr) -> getInstrDesc instr)
                                                                   return (name,instrs))
                  return (name,(pars,tp,blks))) funs
  return $ Map.fromList res

mergePrograms :: Map String ([(String,TypeDesc)],TypeDesc,[(String,[(String,InstrDesc)])]) 
                 -> Map String ([(String,TypeDesc)],TypeDesc,[(String,[(String,InstrDesc)])])
                 -> Map String ([(String,TypeDesc)],TypeDesc,[(String,[(String,InstrDesc)])])
mergePrograms p1 p2 = Map.unionWithKey (\name (args1,tp1,blks1) (args2,tp2,blks2)
                                        -> if fmap snd args1 /= fmap snd args2 || tp1 /= tp2
                                           then error $ "Conflicting signatures for function "++show name++" detected"
                                           else (if Prelude.null blks1
                                                 then (args2,tp2,blks2)
                                                 else (if Prelude.null blks2
                                                       then (args1,tp1,blks1)
                                                       else error $ "Conflicting definitions for function "++show name++" found"))) p1 p2

data MemoryModelOption = UntypedModel
                       | TypedModel
                       | BlockModel
                       deriving (Eq,Ord,Show)

data Options = Options
               { entryPoint :: String
               , bmcDepth :: Integer
               , files :: [String]
               , memoryModel :: MemoryModelOption
               , solver :: Maybe String
               , showHelp :: Bool
               } deriving (Eq,Ord,Show)

defaultOptions :: Options
defaultOptions = Options { entryPoint = "main" 
                         , bmcDepth = 10
                         , files = []
                         , memoryModel = TypedModel
                         , solver = Nothing
                         , showHelp = False }

optionDescr :: [OptDescr (Options -> Options)]
optionDescr = [Option ['e'] ["entry-point"] (ReqArg (\str opt -> opt { entryPoint = str }) "function") "Specify the main function to test"
              ,Option ['d'] ["depth"] (ReqArg (\str opt -> opt { bmcDepth = read str }) "d") "Maximal unroll depth"
              ,Option ['m'] ["memory-model"] (ReqArg (\str opt -> opt { memoryModel = case str of
                                                                           "typed" -> TypedModel
                                                                           "untyped" -> UntypedModel
                                                                           "block" -> BlockModel
                                                                           _ -> error $ "Unknown memory model "++show str
                                                                      }) "model") "Memory model to use (untyped,typed or block)"
              ,Option [] ["solver"] (ReqArg (\str opt -> opt { solver = Just str }) "smt-binary") "The SMT solver to use to solve the generated instance"
              ,Option ['h'] ["help"] (NoArg (\opt -> opt { showHelp = True })) "Show this help"
              ]

getOptions :: IO Options
getOptions = do
  args <- getArgs
  let (res,args',errs) = getOpt Permute optionDescr args
  case errs of
    [] -> return $ foldl (.) id res (defaultOptions { files = args' })
    _ -> error $ show errs

main = do
  opts <- getOptions
  when (showHelp opts) $ do
    putStrLn $ usageInfo "USAGE:\n  furchtbar [OPTION...] FILE [FILE...]\n\nOptions:" optionDescr
    exitSuccess
  progs <- mapM getProgram (files opts)
  let program = foldl1 mergePrograms progs
  withSMTSolver (case solver opts of
                    Nothing -> "~/debug-smt.sh output-" ++ (entryPoint opts) ++ ".smt"
                    Just bin -> bin) $ do
    setOption (PrintSuccess False)
    setOption (ProduceModels True)
    setLogic "QF_ABV"
    (case memoryModel opts of
        TypedModel -> do
          perform program (entryPoint opts) (bmcDepth opts) :: SMT TypedMemory
          return ()
        UntypedModel -> do
          perform program (entryPoint opts) (bmcDepth opts) :: SMT UntypedMemory
          return ()
        BlockModel -> do
          perform program (entryPoint opts) (bmcDepth opts) :: SMT UntypedBlockMemory
          return ()
      )
  where
    perform :: (MemoryModel mem)
               => Map String ([(String,TypeDesc)],TypeDesc,[(String,[(String,InstrDesc)])]) -> String -> Integer -> SMT mem
    perform program entry depth = do
      (mem_in,mem_out,watches) <- translateProgram program entry depth
      checkSat
      dump_in <- memDump mem_in
      dump_out <- memDump mem_out
      liftIO $ putStrLn dump_in
      liftIO $ putStrLn dump_out
      mapM_ (\(name,act,vals) -> do
                ract <- getValue act
                if ract
                  then (do
                           rvals <- mapM (\(tp,val) -> getValue' (fromIntegral $ bitWidth tp) val) vals
                           liftIO $ putStrLn $ "Watchpoint "++name++":"
                             ++concat (fmap (\rval -> " "++show (BitS.toBits rval :: Integer)) rvals))
                  else return ()
            ) watches
      return mem_in

prepareEnvironment :: (MemoryModel mem)
                      => [TypeDesc] -> [(String,TypeDesc)] -> SMT ([Val mem],mem)
prepareEnvironment alltp args = do
  imem <- memNew alltp
  assert $ memInit imem
  foldrM (\(name,tp) (args,mem) -> case tp of
             TDPtr tp -> do
               (ptr,mem') <- memAlloc False tp mem
               return ((PointerValue ptr):args,mem')
             tp -> do
               var <- newValue mem tp
               return (var:args,mem)
         ) ([],imem) args