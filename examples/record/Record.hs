import Extensible
import qualified RecordBase as R
import qualified RecordBase


data WithString

R.extendRec "Rec" [] [t|WithString|] $
  R.defaultExtRec {
    R.typeR1 = Ann ("label1", [t|String|]),
    R.typeR2 = Ann ("label2", [t|String|])
  }

foo :: Rec -> Rec
foo r = r { R.beep = False, R.extR1 = "aaaaaa" }

main :: IO ()
main = pure ()
