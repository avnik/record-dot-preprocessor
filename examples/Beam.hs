-- Input
{-# LANGUAGE GADTs, FlexibleContexts, FlexibleInstances, TypeFamilies, TypeApplications, DeriveGeneric, DeriveAnyClass #-}
-- import Database.Beam

data BarT f = Bar
  { barId :: C f Int
  }

data FooT f = FooT 
  { xBeam :: C f Int
  , yBeam :: C (Nullable f) Int
  , zBeam :: PrimaryKey BarT f
  }

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
