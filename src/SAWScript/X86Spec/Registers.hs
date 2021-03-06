{-# Language RecordWildCards #-}
{-# Language TypeSynonymInstances #-}
{-# Language GADTs #-}
{-# Language TypeFamilies #-}
{-# Language ScopedTypeVariables #-}
{-# Language TypeApplications #-}
{-# Language DataKinds #-}
{-# Language FlexibleInstances #-}
{-# Language FlexibleContexts #-}
module SAWScript.X86Spec.Registers
  ( -- * Register names
    IP(..)
  , GPReg(..)
  , Flag(..)
  , VecReg(..)
  , X87Status(..)
  , X87Top(..)
  , X87Tag(..)
  , FPReg(..)

    -- * Accessing Register
  , RegType
  , GetReg(..)

   -- * Register assignment
  , RegAssign(..)
  , GPRegVal(..), GPValue(..), GPRegUse(..)
  , macawLookup
  ) where

import qualified Flexdis86 as F

import Lang.Crucible.Simulator.RegValue(RegValue'(RV))

import Data.Macaw.Symbolic.PersistentState(ToCrucibleType)
import qualified Data.Macaw.X86.X86Reg as R

import SAWScript.X86Spec.Types
import SAWScript.X86Spec.Monad


-- | Instruciotn pointer.
data IP = IP
  deriving (Show,Eq,Ord,Enum,Bounded)

-- | General purpose register.
data GPReg = RAX | RBX | RCX | RDX | RSI | RDI | RSP | RBP
           | R8  | R9  | R10 | R11 | R12 | R13 | R14 | R15
  deriving (Show,Eq,Ord,Enum,Bounded)

-- | General purpose reigsters may contain either a bit-value or a pointer.
-- This type specifies which form we want to access.
data GPRegUse t where
  AsBits :: GPRegUse (Bits 64)
  AsPtr  :: GPRegUse APtr

-- | The value of a general purpose register.
data GPRegVal = GPBits (Value (Bits 64)) | GPPtr (Value APtr)

-- | A convenient way to construct general purpose values, based on their type.
class GPValue t where
  gpValue :: Value t -> GPRegVal

instance (n ~ 64) => GPValue (Bits n) where gpValue = GPBits
instance GPValue APtr                 where gpValue = GPPtr


-- | CPU flags
data Flag = CF | PF | AF | ZF | SF | TF | IF | DF | OF
  deriving (Show,Eq,Ord,Enum,Bounded)


-- | Vector registers.
data VecReg =
    YMM0  | YMM1  | YMM2  | YMM3  | YMM4  | YMM5  | YMM6  | YMM7
  | YMM8  | YMM9  | YMM10 | YMM11 | YMM12 | YMM13 | YMM14 | YMM15
  deriving (Show,Eq,Ord,Enum,Bounded)


-- | X87 status registers.
data X87Status = X87_IE | X87_DE | X87_ZE | X87_OE
               | X87_UE | X87_PE | X87_EF | X87_ES
               | X87_C0 | X87_C1 | X87_C2 | X87_C3
              deriving (Show,Eq,Ord,Enum,Bounded)


-- | Top of X87 register stack.
data X87Top = X87Top
              deriving (Show,Eq,Ord,Enum,Bounded)

-- | X87 tags.
data X87Tag = Tag0 | Tag1 | Tag2 | Tag3
            | Tag4 | Tag5 | Tag6 | Tag7
              deriving (Show,Eq,Ord,Enum,Bounded)

-- | 80-bit floating point registers.
data FPReg = FP0 | FP1 | FP2 | FP3 | FP4 | FP5 | FP6 | FP7
              deriving (Show,Eq,Ord,Enum,Bounded)


-- | A register assignment.
data RegAssign = RegAssign
  { valIP         ::               Value (Bits 64)
  , valGPReg      :: GPReg      -> GPRegVal
  , valVecReg     :: VecReg     -> Value (Bits 256)
  , valFPReg      :: FPReg      -> Value ABigFloat
  , valFlag       :: Flag       -> Value ABool
  , valX87Status  :: X87Status  -> Value ABool
  , valX87Top     ::               Value (Bits 3)
  , valX87Tag     :: X87Tag     -> Value (Bits 2)
  }


-- | Convert a register assignment to a form suitable for Macaw CFG generation.
macawLookup :: RegAssign -> R.X86Reg t -> RegValue' Sym (ToCrucibleType t)
macawLookup RegAssign { .. } reg =
  case reg of
    R.X86_IP -> toRV valIP

    R.RAX -> gp RAX
    R.RBX -> gp RBX
    R.RCX -> gp RCX
    R.RDX -> gp RDX
    R.RSI -> gp RSI
    R.RDI -> gp RDI
    R.RSP -> gp RSP
    R.RBP -> gp RBP
    R.R8  -> gp R8
    R.R9  -> gp R9
    R.R10 -> gp R10
    R.R11 -> gp R11
    R.R12 -> gp R12
    R.R13 -> gp R13
    R.R14 -> gp R14
    R.R15 -> gp R15
    R.X86_GP _ -> error "[bug] Unexpecet general purpose register."

    R.YMM 0  -> vec YMM0
    R.YMM 1  -> vec YMM1
    R.YMM 2  -> vec YMM2
    R.YMM 3  -> vec YMM3
    R.YMM 4  -> vec YMM4
    R.YMM 5  -> vec YMM5
    R.YMM 6  -> vec YMM6
    R.YMM 7  -> vec YMM7
    R.YMM 8  -> vec YMM8
    R.YMM 9  -> vec YMM9
    R.YMM 10 -> vec YMM10
    R.YMM 11 -> vec YMM11
    R.YMM 12 -> vec YMM12
    R.YMM 13 -> vec YMM13
    R.YMM 14 -> vec YMM14
    R.YMM 15 -> vec YMM15
    R.X86_YMMReg _ -> error "[bug] Unexpected YMM register."

    R.X87_FPUReg (F.MMXR 0)  -> fp FP0
    R.X87_FPUReg (F.MMXR 1)  -> fp FP1
    R.X87_FPUReg (F.MMXR 2)  -> fp FP2
    R.X87_FPUReg (F.MMXR 3)  -> fp FP3
    R.X87_FPUReg (F.MMXR 4)  -> fp FP4
    R.X87_FPUReg (F.MMXR 5)  -> fp FP5
    R.X87_FPUReg (F.MMXR 6)  -> fp FP6
    R.X87_FPUReg (F.MMXR 7)  -> fp FP7
    R.X87_FPUReg _ -> error "[bug] Unexpected FPUReg register."

    R.CF -> flag CF
    R.PF -> flag PF
    R.AF -> flag AF
    R.ZF -> flag ZF
    R.SF -> flag SF
    R.TF -> flag TF
    R.IF -> flag IF
    R.DF -> flag DF
    R.OF -> flag OF
    R.X86_FlagReg _ -> error "[bug] Unexpected flag register."

    R.X87_IE -> x87_status X87_IE
    R.X87_DE -> x87_status X87_DE
    R.X87_ZE -> x87_status X87_ZE
    R.X87_OE -> x87_status X87_OE
    R.X87_UE -> x87_status X87_UE
    R.X87_PE -> x87_status X87_PE
    R.X87_EF -> x87_status X87_EF
    R.X87_ES -> x87_status X87_ES
    R.X87_C0 -> x87_status X87_C0
    R.X87_C1 -> x87_status X87_C1
    R.X87_C2 -> x87_status X87_C2
    R.X87_C3 -> x87_status X87_C3

    R.X87_StatusReg n ->
      error ("[bug] Unexpected X87 status register: " ++ show n)

    R.X87_TopReg -> toRV valX87Top

    R.X87_TagReg 0 -> tag Tag0
    R.X87_TagReg 1 -> tag Tag1
    R.X87_TagReg 2 -> tag Tag2
    R.X87_TagReg 3 -> tag Tag3
    R.X87_TagReg 4 -> tag Tag4
    R.X87_TagReg 5 -> tag Tag5
    R.X87_TagReg 6 -> tag Tag6
    R.X87_TagReg 7 -> tag Tag7
    R.X87_TagReg _ -> error "[bug] Unexpecte X87 tag"


  where
  gp r          = case valGPReg r of
                    GPBits x -> toRV x
                    GPPtr x -> toRV x
  vec r         = toRV (valVecReg r)
  fp r          = toRV (valFPReg r)
  flag r        = toRV (valFlag r)
  x87_status r  = toRV (valX87Status r)
  tag r         = toRV (valX87Tag r)



toRV :: Value t -> RegValue' Sym (Rep t)
toRV (Value x) = RV x



-- | The type of value stored in a register.  Used for reading registers.
type family RegType a where
  RegType IP                  = Bits 64
  RegType (GPReg,GPRegUse t)  = t
  RegType Flag                = ABool
  RegType VecReg              = Bits 256
  RegType X87Status           = ABool
  RegType X87Top              = Bits 3
  RegType X87Tag              = Bits 2
  RegType FPReg               = ABigFloat





-- | Get the value of a register.
class GetReg a where
  getReg :: a -> Spec Post (Value (RegType a))


lookupRegGP :: R.X86Reg R.GP -> GPRegUse t -> Spec Post (Value t)
lookupRegGP r how =
  case how of
    AsBits -> do v <- lookupReg r
                 isPtr v False
                 return v
    AsPtr  -> do v <- lookupReg r
                 isPtr v True
                 return v



instance GetReg IP where
  getReg _ = lookupReg R.X86_IP

instance GetReg (GPReg,GPRegUse t) where
  getReg (x,use) =
    case x of
      RAX -> lookupRegGP R.RAX use
      RBX -> lookupRegGP R.RBX use
      RCX -> lookupRegGP R.RCX use
      RDX -> lookupRegGP R.RDX use
      RSI -> lookupRegGP R.RSI use
      RDI -> lookupRegGP R.RDI use
      RSP -> lookupRegGP R.RSP use
      RBP -> lookupRegGP R.RBP use
      R8  -> lookupRegGP R.R8  use
      R9  -> lookupRegGP R.R9  use
      R10 -> lookupRegGP R.R10 use
      R11 -> lookupRegGP R.R11 use
      R12 -> lookupRegGP R.R12 use
      R13 -> lookupRegGP R.R13 use
      R14 -> lookupRegGP R.R14 use
      R15 -> lookupRegGP R.R15 use


instance GetReg Flag where
  getReg f =
    case f of
      CF -> lookupReg R.CF
      PF -> lookupReg R.PF
      AF -> lookupReg R.AF
      ZF -> lookupReg R.ZF
      SF -> lookupReg R.SF
      TF -> lookupReg R.TF
      IF -> lookupReg R.IF
      DF -> lookupReg R.DF
      OF -> lookupReg R.OF


instance GetReg VecReg where
  getReg f =
    case f of
      YMM0  -> lookupReg (R.YMM 0)
      YMM1  -> lookupReg (R.YMM 1)
      YMM2  -> lookupReg (R.YMM 2)
      YMM3  -> lookupReg (R.YMM 3)
      YMM4  -> lookupReg (R.YMM 4)
      YMM5  -> lookupReg (R.YMM 5)
      YMM6  -> lookupReg (R.YMM 6)
      YMM7  -> lookupReg (R.YMM 7)
      YMM8  -> lookupReg (R.YMM 8)
      YMM9  -> lookupReg (R.YMM 9)
      YMM10 -> lookupReg (R.YMM 10)
      YMM11 -> lookupReg (R.YMM 11)
      YMM12 -> lookupReg (R.YMM 12)
      YMM13 -> lookupReg (R.YMM 13)
      YMM14 -> lookupReg (R.YMM 14)
      YMM15 -> lookupReg (R.YMM 15)


instance GetReg X87Status where
  getReg f =
    case f of
      X87_IE -> lookupReg R.X87_IE
      X87_DE -> lookupReg R.X87_DE
      X87_ZE -> lookupReg R.X87_ZE
      X87_OE -> lookupReg R.X87_OE
      X87_UE -> lookupReg R.X87_UE
      X87_PE -> lookupReg R.X87_PE
      X87_EF -> lookupReg R.X87_EF
      X87_ES -> lookupReg R.X87_ES
      X87_C0 -> lookupReg R.X87_C0
      X87_C1 -> lookupReg R.X87_C1
      X87_C2 -> lookupReg R.X87_C2
      X87_C3 -> lookupReg R.X87_C3

instance GetReg X87Top where
  getReg _ = lookupReg R.X87_TopReg


instance GetReg X87Tag where
  getReg t =
    case t of
      Tag0 -> lookupReg (R.X87_TagReg 0)
      Tag1 -> lookupReg (R.X87_TagReg 1)
      Tag2 -> lookupReg (R.X87_TagReg 2)
      Tag3 -> lookupReg (R.X87_TagReg 3)
      Tag4 -> lookupReg (R.X87_TagReg 4)
      Tag5 -> lookupReg (R.X87_TagReg 5)
      Tag6 -> lookupReg (R.X87_TagReg 6)
      Tag7 -> lookupReg (R.X87_TagReg 7)



instance GetReg FPReg where
  getReg t =
    case t of
      FP0 -> lookupReg (fp 0)
      FP1 -> lookupReg (fp 1)
      FP2 -> lookupReg (fp 2)
      FP3 -> lookupReg (fp 3)
      FP4 -> lookupReg (fp 4)
      FP5 -> lookupReg (fp 5)
      FP6 -> lookupReg (fp 6)
      FP7 -> lookupReg (fp 7)
    where fp = R.X87_FPUReg . F.mmxReg

