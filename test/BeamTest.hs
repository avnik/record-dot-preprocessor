-- Very minimal test, actually only instances checked
-- Most of code is copy-paste from original test/PlugunExample.hs and Beam's test sute.
{-# LANGUAGE CPP #-}
{-# LANGUAGE DuplicateRecordFields
  , DeriveGeneric
  , TypeApplications
  , FlexibleContexts
  , DataKinds
  , MultiParamTypeClasses
  , TypeSynonymInstances
  , FlexibleInstances
  , KindSignatures
  , TypeFamilies
  , StandaloneDeriving #-}
{-# OPTIONS_GHC -fplugin=RecordDotPreprocessor #-}

-- Pragmas not work inside ifdef clauses (haven't ideas why)
module BeamTest where
#if __GLASGOW_HASKELL__ < 806
  
main :: IO ()
main = pure ()

#else

-- things that are now treated as comments

import Database.Beam
import Data.Proxy
import Control.Exception

main :: IO ()
main = test1 >> putStrLn "All worked"

(===) :: (Show a, Eq a) => a -> a -> IO ()
a === b = if a == b then pure () else fail $ "Mismatch, " ++ show a ++ " /= " ++ show b

fails :: a -> IO ()
fails val = do
    res <- try $ evaluate val
    case res of
        Left e -> let _ = e :: SomeException in pure ()
        Right _ -> fail "Expected an exception"


-- Input

data BarT f = Bar
  { barId :: C f Int
  } deriving Generic

deriving instance Eq (BarT Identity)
deriving instance Show (BarT Identity)
instance Beamable BarT  
instance Beamable (PrimaryKey BarT)
instance Table BarT where
    data PrimaryKey BarT f = BarId (Columnar f Int) deriving Generic
    primaryKey e = BarId (barId e) 

data FooT f = FooT 
  { xBeam :: C f Int
  , yBeam :: C (Nullable f) Int
  , zBeam :: PrimaryKey BarT f
  } deriving Generic

deriving instance Eq (PrimaryKey BarT Identity)
deriving instance Eq (FooT Identity)
deriving instance Show (PrimaryKey BarT Identity)
deriving instance Show (FooT Identity)

test1 :: IO ()
test1 = do
    -- test expr.lbl
    let bar = Bar 42 :: BarT Identity
    let foo1 = FooT 1 (Just 2) (pk bar) :: FooT Identity
    foo1.xBeam === 1
    let foo = FooT 3 (Just 2) (pk bar) :: FooT Identity
    foo.xBeam === 3
    foo.yBeam === Just 2
    foo{xBeam = 1} === foo1

-- Plugin-generated instances (if *any* field has the shape 'C a b')
    {--
instance HasField "xBeam" (FooT Identity) (Int) where
    hasField r = (setter, getter)
        where getter = xBeam r
              setter a = r { xBeam = a }
              --}
-- instance HasField "y" (FooT Identity) (Maybe Int) where ...
-- instance HasField "z" (FooT Identity) (PrimaryKey BarT Identity) where ...
-- Rules

--     C f a -> a
--     C (Nullable f) a -> Maybe a
--     x -> x with 'f' replaced by 'Identity' everywhere

#endif

