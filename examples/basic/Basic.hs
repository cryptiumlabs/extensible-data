{-# LANGUAGE FlexibleInstances, TypeSynonymInstances, StandaloneDeriving #-}
import BasicBase

data NoExt

extendA "A" [] [t|NoExt|] $ \_ -> defaultExtA

deriving instance Show a => Show (A a)

main :: IO ()
main = pure () -- print $ (B (A 5) (A 5) :: A Int)
