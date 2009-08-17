{-# LANGUAGE MultiParamTypeClasses, FunctionalDependencies, FlexibleInstances, TypeSynonymInstances, FlexibleContexts, UndecidableInstances, OverlappingInstances, PatternGuards #-}

module Editing.EditsPreparation (prepareEdits, use_tests) where

import qualified Cxx.Basics
import qualified Cxx.Parse
import qualified Editing.Diff
import qualified Data.List as List
import qualified Data.Char as Char
import qualified Editing.Show
import Data.Maybe (mapMaybe)
import Control.Monad (liftM2)
import Cxx.Operations (findDeclaration, findBody)
import Control.Monad.Error ()

import Util ((.), Convert(..), Op(..), ops_cost, unne, erase_indexed, levenshtein, replaceAllInfix, approx_match, Cost, Invertible(..), Ordinal(..), test_cmp, strip, NElist(..), nth_ne, once_twice_thrice)

import Prelude hiding (last, (.), all, (!!))
import Editing.Basics

type ARange = BefAft -> Anchor

arange :: Anchor -> Anchor -> ARange
arange x _ Before = x
arange _ x After = x

anchor_range :: Range a -> ARange
anchor_range (Range x y) = arange (Anchor After x) (Anchor Before (x + y))

unanchor_range :: ARange -> Range a
unanchor_range r | Anchor _ x <- r Before, Anchor _ y <- r After = Range x (y - x)

class Offsettable a where offset :: Int -> a -> a

instance Offsettable (Range Char) where offset x (Range y z) = Range (y + x) z
instance Offsettable Anchor where offset x (Anchor y z) = Anchor y (z + x)
instance Offsettable ARange where offset x r = offset x . r
instance Offsettable a => Offsettable [a] where offset x = (offset x .)

class FindInStr a b | a -> b where findInStr :: (Functor m, Monad m) => String -> Range Char -> a -> m b

instance Convert (Range Char) [ARange] where convert = (:[]) . anchor_range
instance Convert (Range Char) ARange where convert = anchor_range

instance Convert Anchor (Pos Char) where convert = anchor_pos

instance FindInStr (Around Substrs) [ARange] where findInStr s r (Around x) = concat . findInStr s r x

instance FindInStr (Ranked (Either NamedEntity String)) ARange where
  findInStr s r (Ranked o (Left x)) = findInStr s r $ Ranked o x
  findInStr s r (Ranked o (Right x)) = findInStr s r $ Ranked o x
  findInStr s r (Sole (Left x)) = findInStr s r $ Sole x
  findInStr s r (Sole (Right x)) = findInStr s r $ Sole x

instance FindInStr (Ranked String) ARange where
  findInStr t r (Ranked o@(Ordinal n) s) = case find_occs s (selectRange r t) of
    [] -> fail $ "String `" ++ s ++ "` does not occur."
    (a:b) -> case nth_ne o (NElist a b) of
      Just g -> return $ anchor_range $ Range g $ length s
      Nothing -> fail $ "String `" ++ s ++ "` does not occur " ++ once_twice_thrice (if n < 0 then -n else n+1) ++ "."
  findInStr s r (Sole x) = case find_occs x (selectRange r s) of
    [z] -> return $ anchor_range $ Range z (length x)
    [] -> fail $ "String `" ++ x ++ "` does not occur."
    _ -> fail $ "String `" ++ x ++ "` occurs multiple times."

instance Convert ARange (Range Char) where convert = unanchor_range

instance (Offsettable b, Invertible a, FindInStr a b, Convert (Range Char) b) => FindInStr (Relative a) b where
  findInStr s r@(Range a b) (Relative o ba w) = do
    Range st si <- unanchor_range . findInStr s r w
    case ba of
      Before -> findInStr s (Range a st) (invert o)
      After -> offset (st + si) . findInStr s (Range (a + st + si) (b - st - si)) o
  findInStr s r (Between o (Betw b e)) = do
    x <- convert . findInStr s r b
    y <- convert . findInStr s r e
    let (p, q) = if either start id x <= either start id (y :: Either (Range Char) (Pos Char)) then (x, y) else (y, x)
    let p' = either end id p; q' = either start id q
    offset p' . findInStr s (Range (start r + p') (q' - p')) o
  findInStr s r (In o incl) = do
    ar <- findInStr s r incl
    let p = convert $ ar Before; q = convert $ ar After
    offset p . findInStr s (Range (start r + p) (q - p)) o
  findInStr s r@(Range st si) (FromTill b e) = do
    x <- convert . findInStr s r b
    let p = either start id (x :: Either (Range Char) (Pos Char))
    y <- convert . findInStr s (Range (st+p) (si-p)) e
    return $ convert (Range p (either end id (y :: Either (Range Char) (Pos Char))) :: Range Char)

everything_arange :: String -> ARange
everything_arange _ Before = Anchor Before 0
everything_arange s After = Anchor After (length s)

instance FindInStr Substr ARange where
  findInStr s r Everything = return $ everything_arange $ selectRange r s
  findInStr s r (NotEverything x) = findInStr s r x

instance FindInStr (EverythingOr (Rankeds (Either NamedEntity String))) [ARange] where
  findInStr s r Everything = return [everything_arange $ selectRange r s]
  findInStr s r (NotEverything x) = findInStr s r x

instance FindInStr (Rankeds (Either NamedEntity String )) [ARange] where
  findInStr s r (All (Right x)) = findInStr s r (All x)
  findInStr s r (All (Left x)) = findInStr s r (All x)
  findInStr s r (Sole' (Right x)) = findInStr s r (Sole' x)
  findInStr s r (Sole' (Left x)) = unne . findInStr s r x
  findInStr x u (Rankeds (AndList rs) s) = sequence $ (\r -> findInStr x u (Ranked r s)) . unne rs
  findInStr s r (AllBut a (Right x)) = findInStr s r (AllBut a x)
  findInStr s r (AllBut a (Left x)) = findInStr s r (AllBut a x)

instance FindInStr (Rankeds String) [ARange] where
  findInStr y r (All x) = case find_occs x (selectRange r y) of
    [] -> fail $ "String `" ++ x ++ "` does not occur."
    l -> return $ (anchor_range . flip Range (length x)) . l
  findInStr y r (Sole' x) = case find_occs x (selectRange r y) of
    [z] -> return [anchor_range $ Range z (length x)]
    [] -> fail $ "String `" ++ x ++ "` does not occur."
    _ -> fail $ "String `" ++ x ++ "` occurs multiple times."
  findInStr x u (Rankeds (AndList rs) s) = sequence $ (\r -> findInStr x u (Ranked r s)) . unne rs
  findInStr x u (AllBut (AndList rs) s) =
    return $ (anchor_range . flip Range (length s)) . erase_indexed (ordinal_carrier . unne rs) (find_occs s $ selectRange u x)

instance FindInStr NamedEntity (NElist ARange) where
  findInStr s (Range st si) d = case Cxx.Parse.parseRequest s of
    Left e -> fail $ "Could not parse code in previous request. " ++ e
    Right r -> case d of
      DeclarationOf did -> case mapMaybe f $ findDeclaration did r of
        [] -> fail $ "Could not find free declaration of " ++ strip (show did) ++ "."
        (x:y) -> return $ fmap convert $ NElist x y
      BodyOf did -> case mapMaybe f $ findBody did r of
        [] -> fail $ "Could not find body of " ++ strip (show did) ++ "."
        (x:y) -> return $ fmap convert $ NElist x y
    where
      f :: Range Char -> Maybe (Range Char)
      f (Range x y)
        | st <= x, x + y <= st + si = Just $ Range (x - st) y
        | otherwise = Nothing

show_plural :: NamedEntity -> String
show_plural (DeclarationOf did) = "declarations of " ++ strip (show did)
show_plural (BodyOf did) = "bodies of " ++ strip (show did)

instance FindInStr (Ranked NamedEntity) ARange where
  findInStr s r (Sole decl) = do
    NElist x y <- findInStr s r decl
    if null y then return x else fail $ "Multiple " ++ show_plural decl ++ " occur."
  findInStr s u (Ranked o decl) = do
    l <- findInStr s u decl
    case nth_ne o l of
      Nothing -> fail $ "Could not find a " ++ show o ++ " " ++ Editing.Show.show decl ++ "."
      Just r -> return r

instance FindInStr InClause ARange where findInStr s r (InClause x) = findInStr s r x

instance FindInStr AppendPositionsClause [Anchor] where
  findInStr s r (NonAppendPositionsClause pc) = findInStr s r pc
  findInStr s r (AppendIn incl) = fmap (\ar -> [ar After]) $ findInStr s r incl

instance FindInStr PrependPositionsClause [Anchor] where
  findInStr s r (NonPrependPositionsClause pc) = findInStr s r pc
  findInStr s r (PrependIn incl) = fmap (\ar -> [ar Before]) $ findInStr s r incl

instance FindInStr (Rankeds NamedEntity) [ARange] where
  findInStr s r (All decl) = unne . findInStr s r decl
  findInStr s r (Sole' decl) = do
    NElist x y <- findInStr s r decl
    if null y then return [x] else fail $ "Multiple " ++ show_plural decl ++ " occur."
  findInStr x u (Rankeds (AndList rs) s) = sequence $ (\r -> findInStr x u (Ranked r s)) . unne rs
  findInStr x r (AllBut (AndList rs) decl) =
    erase_indexed (ordinal_carrier . unne rs) . unne . findInStr x r decl

instance (FindInStr x a, FindInStr y a) => FindInStr (Either x y) a where
  findInStr s r = either (findInStr s r) (findInStr s r)

instance FindInStr PositionsClause [Anchor] where
  findInStr s r (PositionsClause Before (AndList o)) = (($ Before) .) . concat . sequence (findInStr s r . unne o)
  findInStr s r (PositionsClause After (AndList o)) = (($ After) .) . concat . sequence (findInStr s r . unne o)

instance FindInStr a b => FindInStr (AndList a) [b] where
  findInStr s r (AndList l) = sequence (findInStr s r . unne l)

instance FindInStr Replacer [Edit] where
  findInStr s u (Replacer p r) = (flip RangeReplaceEdit r .) . concat . ((unanchor_range .) .) . findInStr s u p
  findInStr _ _ (ReplaceOptions o o') = return [RemoveOptions o, AddOptions o']

instance FindInStr Changer [Edit] where
  findInStr s u (Changer p r) = (flip RangeReplaceEdit r .) . concat . ((unanchor_range .) .) . findInStr s u p
  findInStr _ _ (ChangeOptions o o') = return [RemoveOptions o, AddOptions o']

instance FindInStr Eraser [Edit] where
  findInStr s r (EraseText (AndList l)) = ((flip RangeReplaceEdit "" . unanchor_range) .) . concat . sequence (findInStr s r . unne l)
  findInStr _ _ (EraseOptions o) = return [RemoveOptions o]
  findInStr s r (EraseAround (Wrapping x y) (Around z)) = liftM2 (++) (f Before) (f After)
    where
      w Before = x; w After = y
      f ba = findInStr s r $ EraseText $ and_one $ Relative (NotEverything $ Rankeds (AndList $ NElist (Ordinal 0) []) (Right $ w ba)) ba z

instance FindInStr Bound (Either ARange Anchor) where
  findInStr s r (Bound Nothing Everything) = return $ Left $ everything_arange $ selectRange r s
  findInStr _ _ (Bound (Just Before) Everything) = return $ Right $ Anchor Before 0
  findInStr _ r (Bound (Just After) Everything) = return $ Right $ Anchor After $ size r
  findInStr s r (Bound mba p) = maybe Left (\ba -> Right . ($ ba)) mba . findInStr s r p

instance FindInStr RelativeBound (Either ARange Anchor) where
  findInStr _ _ Front = return $ Right $ Anchor Before 0
  findInStr _ r Back = return $ Right $ Anchor After $ size r
  findInStr s r (RelativeBound mba p) = maybe Left (\ba -> Right . ($ ba)) mba . findInStr s r p

instance FindInStr Mover Edit where
  findInStr s u (Mover o p) = do
    a <- findInStr s u p
    r <- unanchor_range . findInStr s u o
    makeMoveEdit a r

instance FindInStr Swapper [Edit] where
  findInStr s r (Swapper x y) = do
    a <- findInStr s r x; b <- findInStr s r y
    return $ makeMoveEdit (b Before) (unanchor_range a) ++ makeMoveEdit (a Before) (unanchor_range b) -- By executing makeMoveEdit in the list monad, we nicely filter edits that would be considered overlapping (for example when swapping adjacent ranges).

instance FindInStr Position Anchor where
  findInStr s r (Position ba x) = ($ ba) . findInStr s r x

instance FindInStr UseClause Edit where
  findInStr _ _ (UseOptions o) = return $ AddOptions o
  findInStr s r (UseString z) = do
    if y == 0 || ops_cost owc > fromIntegral (length z) / 1.5 then fail "No match."
      else return $ RangeReplaceEdit (Range x y) z
   where
    text_tokens = edit_tokens Char.isAlphaNum $ selectRange r s
    pattern_tokens = edit_tokens Char.isAlphaNum z
    (x, y) = (sum $ length . take stt text_tokens, sum $ length . take siz (drop stt text_tokens))
    (owc, stt, siz) = head $ approx_match token_edit_cost pattern_tokens (replaceAllInfix pattern_tokens (replicate (length pattern_tokens) (replicate 100 'X')) text_tokens)

token_edit_cost :: Op String -> Cost
token_edit_cost (SkipOp (' ':_)) = 0
token_edit_cost (SkipOp x) | x `elem` Cxx.Basics.keywords = -2.4
token_edit_cost (SkipOp (h:t)) | Char.isAlphaNum h = -2.2 - fromIntegral (length t) * 0.2
token_edit_cost (SkipOp _) = -2
token_edit_cost (EraseOp (' ':_)) = 0.02
token_edit_cost (EraseOp x) = token_edit_cost (InsertOp x)
token_edit_cost (InsertOp t) | t `elem` Cxx.Basics.keywords = 2
token_edit_cost (InsertOp (' ':_)) = -0.02
token_edit_cost (InsertOp x@(y:_)) | Char.isAlpha y = fromIntegral (length x) * 0.7
token_edit_cost (InsertOp (x:y)) | Char.isDigit x = 1 + fromIntegral (length y) * 0.3
token_edit_cost (InsertOp _) = 1
token_edit_cost (ReplaceOp x y)
  | or $ (\c -> List.all (`elem` c) [x, y]) . [Cxx.Basics.classKeys, Cxx.Basics.accessSpecifiers, Cxx.Basics.relational_ops] = 0.4
token_edit_cost (ReplaceOp (c:_) (d:_)) | not (Char.isAlphaNum c || Char.isAlphaNum d) = 1.1
token_edit_cost (ReplaceOp x@(c:_) y@(d:_)) | Char.isAlpha c && Char.isAlpha d =
  if null (List.intersect x y) then 10 else levenshtein x y * 0.4
token_edit_cost (ReplaceOp x@(c:_) y@(d:_)) | Char.isAlphaNum c && Char.isAlphaNum d = levenshtein x y * 0.8
token_edit_cost (ReplaceOp _ _) = 10
  -- The precise values of these costs are fine-tuned to make the tests pass, and that is their only justification. We're trying to approximate the human intuition for what substring should be replaced, as codified in the tests.

instance FindInStr Command [Edit] where
  findInStr s r (Use (AndList l)) = sequence $ findInStr s r . unne l
  findInStr s r (Append x Nothing) = return [InsertEdit (Anchor After (length $ selectRange r s)) x] -- todo: simplify
  findInStr _ _ (Prepend x Nothing) = return [InsertEdit (Anchor Before 0) x]
  findInStr s u (Append r (Just p)) = (flip InsertEdit r .) . concat . findInStr s u p
  findInStr s u (Prepend r (Just p)) = (flip InsertEdit r .) . concat . findInStr s u p
  findInStr s r (Erase (AndList l)) = concat . sequence (findInStr s r . unne l)
  findInStr s r (Replace (AndList l)) = concat . sequence (findInStr s r . unne l)
  findInStr s r (Change (AndList l)) = concat . sequence (findInStr s r . unne l)
  findInStr s u (Insert r p) = (flip InsertEdit r .) . concat . findInStr s u p
  findInStr s r (Move (AndList movers)) = sequence (findInStr s r . unne movers)
  findInStr s r (Swap (AndList swappers)) = concat . sequence (findInStr s r . unne swappers)
  findInStr s u (WrapAround (Wrapping x y) z) = concat . ((\r -> [InsertEdit (r Before) x, InsertEdit (r After) y]) .) . concat . findInStr s u z
  findInStr s r (WrapIn z (Wrapping x y)) = findInStr s r $ WrapAround (Wrapping x y) $ and_one $ Around z

prepareEdits :: (Functor m, Monad m) => String -> Command -> m [Edit]
prepareEdits s = findInStr s (Range 0 (length s))

use_tests :: IO ()
use_tests = do
  t "ETYPE_DESC" "ETPYE" "Replaced `<< ETPYE` with `<< ETYPE_DESC`." "Replaced `<< ETYPE_DESC` with `<< ETPYE`."
  t "kip(a.~T)" "a.~T" "Replaced a.~T with kip(a.~T)." "Replaced kip(a.~T) with a.~T."
  -- t "cos(a.~T)" "a.~T" -- Fails, but can probably be made to work by rewarding successive skips.
  t "size_type" "size_t" "Replaced `string::size_t- siz` with `string::size_type- siz`." "Replaced `string::size_type- siz` with `string::size_t- siz`."
  t "size = 9" "siz = 2" "Replaced `string::size_t- siz = 2` with `string::size_t- size = 9`." "Replaced `string::size_t- size = 9` with `string::size_t- siz = 2`."
  t "ETYPE" "ETPYE" "Replaced `<< ETPYE` with `<< ETYPE`." "Replaced `<< ETYPE` with `<< ETPYE`."
  t "std::string" "string" "Replaced `string::size_t- siz` with `std::string::size_t- siz`." "Replaced `std::string::size_t- siz` with `string::size_t- siz`."
  t "; float x" "; int x" "Replaced `int x` with `float x`." "Replaced `float x` with `int x`."
  t "x-" "x -" "Replaced `x - size` with `x- size`." "Replaced `x- size` with `x - size`."
  t ") cin <<" ") cout <<" "Replaced cout with cin." "Replaced cin with cout."
  t "x = 4" "x = 3" "Replaced 3 with 4." "Replaced 4 with 3."
  t "x - 8);" "x - size);" "Replaced `x - size` with `x - 8`." "Replaced `x - 8` with `x - size`."
  t "(!i)" "(i == 0)" "Replaced `i == 0` with !i."  "Replaced !i with `i == 0`."
  t "seekp" "seek" "Replaced a.seek with a.seekp." "Replaced a.seekp with a.seek."
  t "<char>" "<unsigned char>" "Replaced `vector<unsigned char> & r` with `vector<char> & r`." "Replaced `vector<char> & r` with `vector<unsigned char> & r`."
  t "<const fish>" "<fish>" "Replaced `reinterpret_cat<fish>` with `reinterpret_cat<const fish>`." "Replaced `reinterpret_cat<const fish>` with `reinterpret_cat<fish>`."
  t "&); };" "&) };" "Inserted semicolon after `C const &)`." "Erased semicolon after `C const &)`."
  t "> * r = v" "> & r = v" "Replaced `& r` with `* r`." "Replaced `* r` with `& r`."
  t "v.cbegin()" "v.begin()" "Replaced v.begin with v.cbegin." "Replaced v.cbegin with v.begin."
  -- Todo: "void foo" should match "voidfoo".
  t "x - sizeof(y))" "x - size)" "Replaced `x - size` with `x - sizeof(y)`." "Replaced `x - sizeof(y))` with `x - size)`."
  t "int a(2);" "int a;" "Inserted (2) after `{ int a`." "Erased (2) after `{ int a`."
  t "int const * w" "int * w" "Replaced `int * w` with `int const * w`." "Replaced `int const * w` with `int * w`."
  t "main(int argc) {" "main() {" "Inserted `int argc` after `void main(`." "Erased `int argc`."
  t "_cast" "_cat" "Replaced `reinterpret_cat<fish>` with `reinterpret_cast<fish>`." "Replaced `reinterpret_cast<fish>` with `reinterpret_cat<fish>`."
  t "(++a)" "(a++)" "Replaced a++ with ++a." "Replaced ++a with a++."
  t "list<int>" "vector<int>" "Replaced `vector<int> v` with `list<int> v`." "Replaced `list<int> v` with `vector<int> v`."
  t "a->seekp" "a.seek" "Replaced a.seek with a->seekp." "Replaced a->seekp with a.seek."
  t "vector<int>::iterator i" "vector<int> i" "Replaced `vector<int> i` with `vector<int>::iterator i`." "Replaced `vector<int>::iterator i` with `vector<int> i`."
  t "runtime_error(" "runtime_exception(" "Replaced `throw runtime_exception` with `throw runtime_error`." "Replaced `throw runtime_error` with `throw runtime_exception`."
  t "~T();" "~T;" "Inserted () after `) { a.~T`." "Erased () after `) { a.~T`." -- Todo: ugly.
  t "int const * w" "int * w" "Replaced `int * w` with `int const * w`." "Replaced `int const * w` with `int * w`."
  t "(T & a)" "(T a)" "Replaced `T a` with `T & a`." "Replaced `T & a` with `T a`."
  t "& r(v);" "& r = v;" "Replaced `= v` after `vector<unsigned char> & r` with (v)." "Replaced (v) after `vector<unsigned char> & r` with `= v`."
  t "ios_base::end_t" "ios::end" "Replaced ios::end with `ios_base::end_t`.""Replaced `ios_base::end_t` with ios::end."
  t "95" "94" "Replaced 94 with 95." "Replaced 95 with 94."
  t "vector<int> const v { 3, 2 };" "vector<int> v; v = { 3, 2 };" "Replaced `vector<int> v; v =` with `vector<int> const v`." "Replaced `vector<int> const v` with `vector<int> v; v =`."
  t "class C" "struct C" "Replaced `struct C` with `class C`." "Replaced `class C` with `struct C`."
  t "B z{p};" "B z = B{p};" "Erased `= B` after `B z`." "Inserted `= B` after `B z`."
  t "friend C & operator+" "C & operator+" "Inserted friend before `C & operator+`." "Erased friend before `C & operator+`."
  t "char const(&here)[N]" "char(const&here)[N]" "Replaced `char(const&here` with `char const(&here`." "Replaced `char const(&here` with `char(const&here`."
  t "z = shared_ptr<B>{new p}" "z = B{p}" "Replaced B{p with `shared_ptr<B>{new p`." "Replaced `shared_ptr<B>{new p` with B{p." -- Todo: ugly.
  t "(X(y));" "X(y);" "Inserted ( before X(y) and inserted ) after `} X(y)`." "Erased ( before X(y)) and ) after `} (X(y)`." -- Todo: ugly.
  t "2000" "1800" "Replaced 1800 with 2000." "Replaced 2000 with 1800."
  t "8000100808" "10000000000" "Replaced 10000000000 with 8000100808." "Replaced 8000100808 with 10000000000."
  t "> 7" ">= 7" "Replaced `x >= 7` with `x > 7`." "Replaced `x > 7` with `x >= 7`."
  t "private: fstream" "public: fstream" "Replaced `public: fstream p` with `private: fstream p`." "Replaced `private: fstream p` with `public: fstream p`." -- Todo: "replaced public: with private: before fstream p".
  t "int main" "void main" "Replaced `void main` with `int main`." "Replaced `int main` with `void main`." -- Todo: One day this should say: "Made main return int."
  t "<char>" "<unsigned char>" "Replaced `vector<unsigned char> & r` with `vector<char> & r`." "Replaced `vector<char> & r` with `vector<unsigned char> & r`."
  t "int const u =" "int x =" "Replaced `int x` with `int const u`." "Replaced `int const u` with `int x`."
  t "u - -j" "u--j" "Replaced &u--j with `&u - -j`." "Replaced `&u - -j` with &u--j."
  t "struct C{" "struct C(){" "Erased () after `struct C`." "Inserted () after `struct C`."
  t "&ETPYE" "ETPYE" "Replaced ETPYE with &ETPYE." "Replaced &ETPYE with ETPYE."
  putStrLn "All use tests passed."
 where
  u :: String -> String -> String -> String -> String -> IO ()
  u txt pattern match d rd = do
    RangeReplaceEdit rng _ <- findInStr txt (Range 0 (length txt)) (UseString pattern)
    test_cmp pattern match (selectRange rng txt)
    let r = replaceRange rng pattern txt
    test_cmp pattern d $ show $ Editing.Diff.diff txt r
    test_cmp (pattern ++ " (reverse)") rd $ show $ Editing.Diff.diff r txt
  t :: String -> String -> String -> String -> IO ()
  t = u "{ string::size_t- siz = 2; int x = 3; if(i == 0) cout << ETPYE(x - size); vector<int> v; v = { 3, 2 }; vector<int> i = reinterpret_cat<fish>(10000000000, v.begin()); } X(y); using tracked::B; B z = B{p}; int const u = 94; int * w = &u--j; !B && !D; vector<unsigned char> & r = v; struct C(){ C & operator+(ostream &, char(const&here)[N], C const &) }; template<typename T> voidfoo(T a) { a.~T; } void main() { int a; a.seek(1800, ios::end); foo(a++); if(x >= 7) throw runtime_exception(y); } class Qbla { public: fstream p; };"
