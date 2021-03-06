{-# Language DataKinds, OverloadedStrings #-}
{-# Language RankNTypes, TypeOperators #-}
{-# Language PatternSynonyms #-}
module SAWScript.X86
  ( Options(..)
  , proof
  , proofWithOptions
  , linuxInfo
  , bsdInfo
  , Fun(..)
  , Goal(..)
  , gGoal
  , X86Error(..)
  , X86Unsupported(..)
  , SharedContext
  , CallHandler
  , Sym
  ) where


import Control.Lens (toListOf, folded, (^.))
import Control.Exception(Exception(..),throwIO)
import Control.Monad.ST(ST,stToIO,RealWorld)

import qualified Data.AIG as AIG
import           Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import           Data.Map ( Map)
import qualified Data.Map as Map
import qualified Data.Text as Text
import           Data.Text.Encoding(decodeUtf8)
import           GHC.Natural(Natural)
import           System.IO(hFlush,stdout)

import Data.ElfEdit (Elf, parseElf, ElfGetResult(..))

import Data.Parameterized.Some(Some(..))
import Data.Parameterized.Classes(knownRepr)
import Data.Parameterized.Context(Assignment,EmptyCtx,(::>),singleton)
import Data.Parameterized.Nonce(globalNonceGenerator)

-- What4
import What4.Interface(asNat,asUnsignedBV)
import What4.FunctionName(functionNameFromText)
import What4.ProgramLoc(ProgramLoc,Position(OtherPos))

-- Crucible
import Lang.Crucible.Analysis.Postdom (postdomInfo)
import Lang.Crucible.CFG.Core(SomeCFG(..), TypeRepr(..), cfgHandle)
import Lang.Crucible.CFG.Common(freshGlobalVar,GlobalVar)
import Lang.Crucible.Simulator.RegMap(regValue, RegMap(..), RegEntry(..))
import Lang.Crucible.Simulator.RegValue(RegValue,RegValue'(..))
import Lang.Crucible.Simulator.GlobalState(lookupGlobal,insertGlobal,emptyGlobals)
import Lang.Crucible.Simulator.Operations(defaultAbortHandler)
import Lang.Crucible.Simulator.OverrideSim(runOverrideSim, callCFG)
import Lang.Crucible.Simulator.EvalStmt(executeCrucible)
import Lang.Crucible.Simulator.ExecutionTree
          (GlobalPair,gpValue,ExecResult(..),PartialResult(..)
          , gpGlobals, AbortedResult(..), SimContext(..), FnState(..)
          , initSimState
          )
import Lang.Crucible.Simulator.SimError(SimError(..), SimErrorReason)
import Lang.Crucible.Backend
          (getProofObligations,ProofGoal(..),labeledPredMsg,labeledPred,proofGoalsToList)
import Lang.Crucible.FunctionHandle(HandleAllocator,newHandleAllocator,insertHandleMap,emptyHandleMap)


-- Crucible LLVM
import SAWScript.CrucibleLLVM
  (Mem, ppMem, ppPtr, pattern LLVMPointer, bytesToInteger)
import Lang.Crucible.LLVM.Intrinsics(llvmIntrinsicTypes)
import Lang.Crucible.LLVM.MemModel (mkMemVar)

-- Crucible SAW
import Lang.Crucible.Backend.SAWCore
  (newSAWCoreBackend, toSC, sawBackendSharedContext
  , sawRegisterSymFunInterp)

-- Macaw
import Data.Macaw.Architecture.Info(ArchitectureInfo)
import Data.Macaw.Discovery(analyzeFunction)
import Data.Macaw.Discovery.State(FunctionExploreReason(UserRequest)
                                 , emptyDiscoveryState)
import Data.Macaw.Memory( Memory, MemSymbol(..), MemSegmentOff(..)
                        , AddrSymMap, segmentBase, segmentOffset
                        , addrOffset, memWordInteger
                        , relativeSegmentAddr, incAddr
                        , readWord8, readWord16le, readWord32le, readWord64le)
import Data.Macaw.Memory.ElfLoader( LoadOptions(..)
                                  , memoryForElfAllSymbols )
import Data.Macaw.Symbolic( ArchRegStruct
                          , ArchRegContext,mkFunCFG
                          , GlobalMap
                          , MacawSimulatorState(..)
                          , macawExtensions
                          )
import qualified Data.Macaw.Symbolic as Macaw ( LookupFunctionHandle(..) )
import Data.Macaw.Symbolic.CrucGen( MacawSymbolicArchFunctions(..)
                                  , MacawExt
                                  , MacawFunctionArgs
                                  , crucArchRegTypes
                                  )
import Data.Macaw.Symbolic.PersistentState(macawAssignToCrucM)
import Data.Macaw.X86(X86Reg(..), x86_64_linux_info,x86_64_freeBSD_info)
import Data.Macaw.X86.ArchTypes(X86_64)
import Data.Macaw.X86.Symbolic
  ( x86_64MacawSymbolicFns, x86_64MacawEvalFn, newSymFuns
  , lookupX86Reg
  )
import Data.Macaw.X86.Crucible(SymFuns(..))


-- Saw Core
import Verifier.SAW.SharedTerm(Term, mkSharedContext, SharedContext, scImplies)
import Verifier.SAW.Term.Pretty(showTerm)

-- Cryptol Verifier
import Verifier.SAW.CryptolEnv(CryptolEnv,initCryptolEnv,loadCryptolModule)
import Verifier.SAW.Cryptol.Prelude(scLoadPreludeModule,scLoadCryptolModule)

-- SAWScript
import SAWScript.X86Spec.Types(Sym)
import SAWScript.X86Spec.Monad(runPreSpec,runPostSpec,PreExtra(..))
import SAWScript.X86Spec.Registers(macawLookup)
import SAWScript.X86Spec (Spec,FunSpec(..),Pre,Post,RegAssign)

import SAWScript.X86SpecNew



--------------------------------------------------------------------------------
-- Input Options


-- | What we'd like done, plus additional information from the "outside world".
data Options = Options
  { fileName  :: FilePath
    -- ^ Name of the elf file to process.

  , function :: Fun
    -- ^ Function that we'd like to extract.

  , archInfo :: ArchitectureInfo X86_64
    -- ^ Architectural flavor.  See "linuxInfo" and "bsdInfo".

  , backend :: Sym
    -- ^ The Crucible backend to use.

  , allocator :: HandleAllocator RealWorld
    -- ^ The handle allocator used to allocate @memvar@

  , memvar :: GlobalVar Mem
    -- ^ The global variable storing the heap

  , funCalls :: Map (Natural,Integer) CallHandler
    {- ^ A mapping for function locations to the code to run to handle
         function calls.  The two integers are the base and offset
         pair representing the address of function.
         The handler is just some code that will be executed instead of
         calling the function.  Typeically, it should assert the functions's
         precondition and asssume its post condition after.

         Note that his works only when the call is completely known
         (i.e., no symbolic stuff, etc.)
    -}

  , cryEnv :: CryptolEnv

  , extraGlobals :: [(ByteString,Integer,Unit)]
    -- ^ Additional globals to auto-load from the ELF file
  }

linuxInfo :: ArchitectureInfo X86_64
linuxInfo = x86_64_linux_info

bsdInfo :: ArchitectureInfo X86_64
bsdInfo = x86_64_freeBSD_info


--------------------------------------------------------------------------------
-- Spec

data Fun = Fun { funName :: ByteString, funSpec :: FunSpec }


--------------------------------------------------------------------------------

type CallHandler = Sym -> Macaw.LookupFunctionHandle Sym X86_64

-- | Run a top-level proof.
-- Should be used when making a standalone proof script.
proof :: (AIG.IsAIG l g) =>
         AIG.Proxy l g ->
         ArchitectureInfo X86_64 ->
         FilePath {- ^ ELF binary -} ->
         Maybe FilePath {- ^ Cryptol spec, if any -} ->
         [(ByteString,Integer,Unit)] ->
         (Sym -> CryptolEnv -> IO (Map (Natural,Integer) CallHandler))
         {- ^ Funciton call handler; used only for OldStyle -} ->
         Fun ->
         IO (SharedContext,Integer,[Goal])
proof proxy archi file mbCry globs mkCallMap fun =
  do sc  <- mkSharedContext
     halloc  <- newHandleAllocator
     scLoadPreludeModule sc
     scLoadCryptolModule sc
     sym <- newSAWCoreBackend proxy sc globalNonceGenerator
     cenv <- loadCry sym mbCry
     callMap <- mkCallMap sym cenv
     mvar <- stToIO (mkMemVar halloc)
     proofWithOptions Options
       { fileName = file
       , function = fun
       , archInfo = archi
       , backend = sym
       , allocator = halloc
       , memvar = mvar
       , funCalls = callMap
       , cryEnv = cenv
       , extraGlobals = globs
       }

-- | Run a proof using the given backend.
-- Useful for integrating with other tool.
proofWithOptions :: Options -> IO (SharedContext,Integer,[Goal])
proofWithOptions opts =
  do elf <- getRelevant =<< getElf (fileName opts)
     translate opts elf (function opts)

-- | Add interpretations for the symbolic functions, by looking
-- them up in the Cryptol environment.  There should be definitions
-- for "aesenc", "aesenclast", and "clmul".
registerSymFuns :: Opts -> IO (SymFuns Sym)
registerSymFuns opts =
  do let sym = optsSym opts
     sfs <- newSymFuns sym

     sawRegisterSymFunInterp sym (fnAesEnc     sfs) (mk2 "aesenc")
     sawRegisterSymFunInterp sym (fnAesEncLast sfs) (mk2 "aesenclast")
     sawRegisterSymFunInterp sym (fnClMul      sfs) (mk2 "clmul")

     return sfs

  where
  err nm xs =
    unlines [ "Type error in call to " ++ show (nm::String) ++ ":"
            , "*** Expected: 2 arguments"
            , "*** Given:    " ++ show (length xs) ++ " arguments"
            ]

  mk2 nm _sc xs = case xs of
                    [_,_] -> cryTerm opts nm xs
                    _     -> fail (err nm xs)

--------------------------------------------------------------------------------
-- ELF

-- | These are the parts of the ELF file that we care about.
data RelevantElf = RelevantElf
  { memory  :: Memory 64
  , symMap  :: AddrSymMap 64
  }

-- | Parse an elf file.
getElf :: FilePath -> IO (Elf 64)
getElf path =
  do bs <- BS.readFile path
     case parseElf bs of
       Elf64Res [] e     -> return e
       Elf64Res _ _      -> malformed "64-bit ELF input"
       Elf32Res _ _      -> unsupported "32-bit ELF format"
       ElfHeaderError {} -> malformed "Invalid ELF header"



-- | Extract a Macaw "memory" from an ELF file and resolve symbols.
getRelevant :: Elf 64 -> IO RelevantElf
getRelevant elf =
  case memoryForElfAllSymbols opts elf of
    Left err -> malformed err
    Right (mem, addrs, _warnings, _errs) ->
      do
{-
         unless (null errs)
           $ malformed $ unlines $ "Failed to resolve ELF symbols:"
                                 : map show errs
-}
         let toEntry msym = (memSymbolStart msym, memSymbolName msym)
         return RelevantElf { memory = mem
                            , symMap = Map.fromList (map toEntry addrs)
                            }

  where
  -- XXX: What options do we want?
  opts = LoadOptions { loadRegionIndex    = Just 0
                     , loadRegionBaseOffset = 0
                     }




-- | Find the address(es) of a symbol by name.
findSymbols :: AddrSymMap 64 -> ByteString -> [ MemSegmentOff 64 ]
findSymbols addrs nm = Map.findWithDefault [] nm invertedMap
  where
  invertedMap = Map.fromListWith (++) [ (y,[x]) | (x,y) <- Map.toList addrs ]

-- | Find the single address of a symbol, or fail.
findSymbol :: AddrSymMap 64 -> ByteString -> IO (MemSegmentOff 64)
findSymbol addrs nm =
  case findSymbols addrs nm of
    [addr] -> return $! addr
    []     -> malformed ("Could not find function " ++ show nm)
    _      -> malformed ("Multiple definitions for " ++ show nm)


loadGlobal ::
  RelevantElf ->
  (ByteString, Integer, Unit) ->
  IO [(String, Integer, Unit, [Integer])]
loadGlobal elf (nm,n,u) =
  case findSymbols (symMap elf) nm of
    [] -> do print $ symMap elf
             err "Global not found"
    _  -> mapM loadLoc (findSymbols (symMap elf) nm)
  where
  mem   = memory elf
  sname = BSC.unpack nm

  readOne a = case u of
                Bytes  -> check (readWord8    mem a)
                Words  -> check (readWord16le mem a)
                DWords -> check (readWord32le mem a)
                QWords -> check (readWord64le mem a)
                _      -> err ("unsuported global size: " ++ show u)

  nextAddr = incAddr (bytesToInteger (1 *. u))

  addrsFor o = take (fromIntegral n) (iterate nextAddr o)

  check :: (Show b, Integral a) => Either b a -> IO Integer
  check res = case res of
                Left e  -> err (show e)
                Right a -> return (fromIntegral a)


  loadLoc off = do let start = relativeSegmentAddr off
                       a  = memWordInteger (addrOffset start)
                   is <- mapM readOne (addrsFor start)
                   return (sname, a, u, is)

  err xs = fail $ unlines
                    [ "Failed to load global."
                    , "*** Global: " ++ show nm
                    , "*** Error: " ++ xs
                    ]


-- | The position associated with a specific location.
posFn :: MemSegmentOff 64 -> Position
posFn = OtherPos . Text.pack . show


-- | Load a file with Cryptol decls.
loadCry :: Sym -> Maybe FilePath -> IO CryptolEnv
loadCry sym mb =
  do ctx <- sawBackendSharedContext sym
     env <- initCryptolEnv ctx
     case mb of
       Nothing   -> return env
       Just file -> snd <$> loadCryptolModule ctx env file


--------------------------------------------------------------------------------
-- Translation

callHandler :: Overrides -> CallHandler
callHandler callMap sym = Macaw.LFH $ \st mem regs -> do
  case lookupX86Reg X86_IP regs of
    Just (RV ptr) | LLVMPointer base off <- ptr ->
      case (asNat base, asUnsignedBV off) of
        (Just b, Just o) ->
           case Map.lookup (b,o) callMap of
             Just h  -> case h sym of
                          Macaw.LFH f -> f st mem regs
             Nothing ->
               fail ("No over-ride for function: " ++ show (ppPtr ptr))

        _ -> fail ("Non-static call: " ++ show (ppPtr ptr))

    _ -> fail "[Bug?] Failed to obtain the value of the IP register."


-- | Verify the given function.  The function matches it sepcification,
-- as long as the returned goals can be discharged.
-- Returns the shared context and the goals (from the Sym)
-- and the integer is the (aboslute) address of the function.
translate ::
  Options -> RelevantElf -> Fun -> IO (SharedContext, Integer, [Goal])
translate opts elf fun =
  do let name = funName fun
     sayLn ("Translating function: " ++ BSC.unpack name)

     let sym   = backend opts
         sopts = Opts { optsSym = sym, optsCry = cryEnv opts, optsMvar = memvar opts }

     sfs <- registerSymFuns sopts

     (globs,st,checkPost) <-
        case funSpec fun of
          OldStyle spec -> doSpecOldStyle opts spec
          NewStyle mkSpec debug ->
            do gss <- mapM (loadGlobal elf) (extraGlobals opts)
               spec0 <- mkSpec (cryEnv opts)
               let spec = spec0 {specGlobsRO = concat (specGlobsRO spec0:gss)}
               (gs,st,po) <- verifyMode spec sopts
               debug st
               let _oldStyle = (fst gs, funCalls opts)
               return (gs,st,\st1 -> debug st1 >> po st1)

     (addr, st1) <- doSim opts elf sfs name globs st

     checkPost st1

     gs <- getGoals sym
     ctx <- sawBackendSharedContext sym
     return (ctx, addr, gs)


doSpecOldStyle ::
  Options ->
  Spec Pre (RegAssign, Spec Post ()) ->
  IO ((GlobalMap Sym 64, Overrides), State, State -> IO ())
doSpecOldStyle opts spec =
  do let sym = backend opts

     ((initRegs,post), extra) <-
        statusBlock "  Setting up pre-conditions... " $
        runPreSpec sym (cryEnv opts) spec

     regs <- macawAssignToCrucM (return . macawLookup initRegs) genRegAssign

     return ( (mkGlobalMap (theRegions extra), funCalls opts)
            , State { stateMem = theMem extra, stateRegs = regs }
            , \st1 -> statusBlock "  Setting-up post-conditions... " $
                      runPostSpec sym (cryEnv opts)
                                      (stateRegs st1)
                                      (stateMem st1)
                                      post
             )



doSim ::
  Options ->
  RelevantElf ->
  SymFuns Sym ->
  ByteString ->
  (GlobalMap Sym 64, Overrides) ->
  State ->
  IO (Integer,State)
doSim opts elf sfs name (globs,overs) st =
  do say "  Looking for address... "
     addr <- findSymbol (symMap elf) name
     let addrInt =
           let seg = msegSegment addr
           in if segmentBase seg == 0
                 then toInteger (segmentOffset seg + msegOffset addr)
                 else error "  Not an absolute address"

     sayLn (show addr)

     SomeCFG cfg <- statusBlock "  Constructing CFG... "
                    $ stToIO (makeCFG opts elf name addr)

     -- writeFile "XXX.hs" (show cfg)

     let sym = backend opts
         mvar = memvar opts

     execResult <- statusBlock "  Simulating... " $ do
       let crucRegTypes = crucArchRegTypes x86
       let macawStructRepr = StructRepr crucRegTypes
       let ctx :: SimContext (MacawSimulatorState Sym) Sym (MacawExt X86_64)
           ctx = SimContext { _ctxSymInterface = sym
                              , ctxSolverProof = \a -> a
                              , ctxIntrinsicTypes = llvmIntrinsicTypes
                              , simHandleAllocator = allocator opts
                              , printHandle = stdout
                              , extensionImpl = macawExtensions (x86_64MacawEvalFn sfs) mvar globs (callHandler overs sym)
                              , _functionBindings =
                                   insertHandleMap (cfgHandle cfg) (UseCFG cfg (postdomInfo cfg)) $
                                   emptyHandleMap
                              , _cruciblePersonality = MacawSimulatorState
                              }
       let initGlobals = insertGlobal mvar (stateMem st) emptyGlobals
       let s = initSimState ctx initGlobals defaultAbortHandler
       executeCrucible s $ runOverrideSim macawStructRepr $ do
         let args :: RegMap Sym (MacawFunctionArgs X86_64)
             args = RegMap (singleton (RegEntry macawStructRepr (stateRegs st)))
         crucGenArchConstraints x86 $
           regValue <$> callCFG cfg args

     gp <- case execResult of
             FinishedResult _ res ->
                case res of
                  TotalRes gp -> return gp
                  PartialRes _pre gp _ab -> return gp
                  -- XXX: we ignore the _pre, as it should be subsumed
                  -- by the assertions in the backend. Ask Rob D. for details.
             AbortedResult _ctx res ->
                   malformed $ unlines [ "Failed to finish execution"
                                       , ppAbort mvar res
                                       ]

     mem <- getMem gp mvar
     return ( addrInt
            , State { stateMem = mem, stateRegs = regValue (gp ^. gpValue) }
            )

ppAbort :: GlobalVar Mem -> AbortedResult Sym b -> String
ppAbort mvar x =
  case x of
    AbortedExec e gp ->
       case lookupGlobal mvar (gp ^. gpGlobals) of
         Just mem -> unlines [ "Aborted execution: " ++ show e
                             , show (ppMem mem) ]
         Nothing -> "Aborted exexution (no memory?)"
    AbortedExit {} -> "Aborted exit"
    AbortedBranch {} -> "Aborted branch"



-- | Get the current model of the memory.
getMem :: GlobalPair Sym a ->
          GlobalVar Mem ->
          IO (RegValue Sym Mem)
getMem st mvar =
  case lookupGlobal mvar (st ^. gpGlobals) of
    Just mem -> return mem
    Nothing  -> fail ("Global heap value not initialized: " ++ show mvar)



type TheCFG = SomeCFG (MacawExt X86_64)
                      (EmptyCtx ::> ArchRegStruct X86_64)
                      (ArchRegStruct X86_64)


-- | Generate a CFG for the function at the given address.
makeCFG ::
  Options ->
  RelevantElf ->
  ByteString ->
  MemSegmentOff 64 ->
  ST RealWorld TheCFG
makeCFG opts elf name addr =
  do (_,Some funInfo) <- analyzeFunction quiet addr UserRequest empty
     baseVar <- freshGlobalVar (allocator opts) baseName knownRepr
     let memBaseVarMap = Map.singleton 1 baseVar
     mkFunCFG x86 (allocator opts) memBaseVarMap cruxName posFn funInfo
  where
  txtName   = decodeUtf8 name
  cruxName  = functionNameFromText txtName
  baseName  = Text.append "mem_base_" txtName

  empty = emptyDiscoveryState (memory elf) (symMap elf) (archInfo opts)



--------------------------------------------------------------------------------
-- Goals

data Goal = Goal
  { gAssumes :: [ Term ]              -- ^ Assuming these
  , gShows   :: Term                  -- ^ We need to show this
  , gLoc     :: ProgramLoc            -- ^ The goal came from here
  , gMessage :: SimErrorReason        -- ^ We should say this if the proof fails
  }

-- | The boolean term that needs proving (i.e., assumptions imply conclusion)
gGoal :: SharedContext -> Goal -> IO Term
gGoal ctx g = go (gAssumes g)
  where
  go xs = case xs of
            []     -> return (gShows g)
            a : as -> scImplies ctx a =<< go as

getGoals :: Sym -> IO [Goal]
getGoals sym =
  do obls <- proofGoalsToList <$> getProofObligations sym
     mapM toGoal obls
  where
  toGoal (ProofGoal asmps g) =
    do as <- mapM (toSC sym) (toListOf (folded . labeledPred) asmps)
       p  <- toSC sym (g ^. labeledPred)
       let SimError loc msg = g^.labeledPredMsg
       return Goal { gAssumes = as
                   , gShows   = p
                   , gLoc     = loc
                   , gMessage = msg
                   }

instance Show Goal where
  showsPrec _ g = showString "Goal { gAssumes = "
                . showList (map (show . showTerm) (gAssumes g))
                . showString ", gShows = " . shows (showTerm (gShows g))
                . showString ", gLoc = " . shows (gLoc g)
                . showString ", gMessage = " . shows (show (gMessage g))
                . showString " }"


--------------------------------------------------------------------------------
-- Specialize the generic functions to the X86.

-- | All functions related to X86.
x86 :: MacawSymbolicArchFunctions X86_64
x86 = x86_64MacawSymbolicFns

genRegAssign :: Assignment X86Reg (ArchRegContext X86_64)
genRegAssign = crucGenRegAssignment x86




--------------------------------------------------------------------------------
-- Calling Convention
-- see: http://refspecs.linuxfoundation.org/elf/x86_64-abi-0.99.pdf
-- Need to preserve: %rbp, %rbx, %r12--%r15
-- Preserve control bits in MXCSR
-- Preserve x87 control word.
-- On entry:
--   CPU is in x87 mode
--   DF in $rFLAGS is clear one entry and return.
-- "Red zone" 128 bytes past the end of the stack %rsp.
--    * not modified by interrupts


--------------------------------------------------------------------------------
-- Logging
quiet :: Applicative m => a -> m ()
quiet _ = pure ()



--------------------------------------------------------------------------------
-- Errors

data X86Unsupported = X86Unsupported String deriving Show
data X86Error       = X86Error String deriving Show

instance Exception X86Unsupported
instance Exception X86Error

unsupported :: String -> IO a
unsupported x = throwIO (X86Unsupported x)

malformed :: String -> IO a
malformed x = throwIO (X86Error x)


--------------------------------------------------------------------------------
-- Status output


say :: String -> IO ()
say x = putStr x >> hFlush stdout

sayLn :: String -> IO ()
sayLn = putStrLn

sayOK :: IO ()
sayOK = sayLn "[OK]"

statusBlock :: String -> IO a -> IO a
statusBlock msg m =
  do say msg
     a <- m
     sayOK
     return a

