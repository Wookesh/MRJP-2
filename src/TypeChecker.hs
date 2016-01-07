{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module TypeChecker where

import AbsLatte
import Control.Monad.State
import LatteState
import TypeCollector
import ConstEval
import Compile
import Common
import Predefined
import ErrM

class TypeChecker a where
	checkType :: MonadState LState m => a -> m ()
	declItem :: MonadState LState m => Type -> a -> m ()
	declItem _ _ = do return ()
	getType :: MonadState LState m => a -> m Type
	getType _ = do return Void

	checkAndGetType :: MonadState LState m => a -> m Type
	checkAndGetType expr = do
		checkType expr
		typ <- getType expr
		return typ
	
	checkReturn :: MonadState LState m => Type -> a -> m ()
	checkReturn _ _ = return ()

	checkLastRet :: MonadState LState m => Type -> Bool -> a -> m Bool
	checkLastRet _ _ _ = return False

---------- type checker
instance TypeChecker Program where
	checkType (Program topDefs) = do
		forM_ topDefs checkType

instance TypeChecker TopDef where
	checkType (TopFun funDef) = do
		checkType funDef
		return ()

	checkType (ClassDef ident classBlock) = do
		f <-runForClass ident $ checkType classBlock
		return ()

	checkType (ClassDefE ident base classBlock) = do
		f <- runForClass ident $ checkType classBlock
		return ()

instance TypeChecker FunDef where
	 checkType f@(FnDef typ ident args block) = do
	 	runForFun ident $ go f
	 	where
	 		go f@(FnDef typ ident args block) = do 
	 			forM_ args declParam
	 			_ <- shouldCall ident $ checkType block
	 			shouldCall ident $ checkReturn typ block
	 			return ()
	 		
	 		declParam (Arg typ ident) = do
	 			declNoShift ident typ
	 		shouldCall (Ident ident) fun = do
	 			if isPredefined ident then
	 				return ()
	 			else do
	 				fun

instance TypeChecker ClassBlock where
	checkType (ClassBlock elems) = do
		forM_ elems checkType
		

instance TypeChecker ClassElem where
	checkType (ClassFun funDef) = do
		checkType funDef

	checkType _ = do
		return ()

instance TypeChecker Block where
	checkType (Block stmts) = do
		runForBlock $ forM_ stmts checkType

	checkReturn typ e@(Block stmts) = do
		forM stmts $ checkReturn typ
		lastIsRet <- foldM (checkLastRet typ) False stmts
		case lastIsRet of
			True -> return ()
			False -> if typ == Void then return () else fail $ "No return at the end of " ++ (show e)



instance TypeChecker Stmt where
	checkType (Empty) = do
		return ()

	checkType (BStmt block) = do
		checkType block

	checkType (Decl typ items) = do
		forM_ items $ declItem typ 
		forM_ items $ checkType

	checkType e@(Ass ident expr) = do
		typ1 <- checkAndGetType expr
		typ2 <- getVarType ident
		isType typ2 typ1 e

	checkType e@(Incr ident) = do
		typ <- getVarType ident
		isType Int typ (Incr ident)

	checkType e@(Decr ident) = do
		typ <- getVarType ident
		isType Int typ e

	checkType e@(Ret expr) = do
		ident <- getFunFromContext
		typ1 <- getFunRetType ident
		typ2 <- getType expr
		isType typ1 typ2 e

	checkType VRet = do
		ident <- getFunFromContext
		typ <- getFunRetType ident
		isType Void typ VRet

	checkType (Cond ELitTrue stmt) = do
		checkType stmt

	checkType (Cond ELitFalse stmt) = do
		return ()

	checkType (Cond expr stmt) = do
		typ <- getType expr
		isType Bool typ expr
		checkType expr
		checkType stmt

	checkType (CondElse expr stmt1 stmt2) = do
		typ <- getType expr
		isType Bool typ expr
		checkType stmt1
		checkType stmt2

	checkType (While expr stmt) = do
		typ <- getType expr
		isType Bool typ expr
		checkType stmt

	checkType (SExp expr) = do
		checkType expr

	checkLastRet typ _ (Cond ELitTrue stmt) = do
		checkReturn typ stmt
		return True

	checkLastRet typ _ (CondElse expr stmt1 stmt2) = do
		checkReturn typ stmt1
		checkReturn typ stmt2
		return True

	checkLastRet typ _ VRet = return True
	checkLastRet typ _ (Ret expr) = return True

	checkLastRet _ _ _ = return False


instance TypeChecker Item where
	checkType (NoInit ident) = do return ()
	checkType e@(Init ident expr) = do
		checkType expr
		typ1 <- getVarType ident
		typ2 <- getType expr
		isType typ1 typ2 e

	declItem typ (NoInit ident) = do
		declNoShift ident typ
	declItem typ (Init ident _) = do
		declNoShift ident typ

instance TypeChecker Arg where
	checkType arg@(Arg typ ident) = do 
		declItem typ arg

	declItem _ (Arg typ ident) = do
		declNoShift ident typ

instance TypeChecker Expr where

	checkType (EApp ident exprs) = do
		types1 <- forM exprs checkAndGetType
		(Fun typ types2) <- getFunType ident
		if (length types1) /= (length types2) then
			fail $ "Wrong number of parameters in " ++ (show ident) ++ ". Should be " ++ (show $ length types2) ++ " is " ++ (show $ length types1) ++ "\n"
		else do
			forM (zip types1 (zip types2 exprs)) (\(t1,(t2,e)) -> do isType t2 t1 e)
			return ()
	
	checkType (EString str) = do
		return ()

	checkType (Neg expr) = do
		typ <- checkAndGetType expr
		isType Int typ expr

	checkType (Not expr) = do
		typ <- checkAndGetType expr
		isType Bool typ expr
	
	checkType (EMul expr1 op expr2) = do
		typ1 <- checkAndGetType expr1
		typ2 <- checkAndGetType expr2
		isType Int typ1 expr1
		isType Int typ2 expr2

	checkType (EAdd expr1 op expr2) = do
		typ1 <- checkAndGetType expr1
		typ2 <- checkAndGetType expr2
		if and [typ1 == Str, op == Plus] then do
			isType Str typ2 expr2
		else do
			isType Int typ1 expr1
			isType Int typ2 expr2

	checkType (ERel expr1 op expr2) = do
		typ1 <- checkAndGetType expr1
		typ2 <- checkAndGetType expr2
		isType typ1 typ2 expr2

	checkType (EAnd expr1 expr2) = do
		typ1 <- checkAndGetType expr1
		typ2 <- checkAndGetType expr2
		isType Bool typ1 expr1
		isType Bool typ2 expr2

	checkType (EOr expr1 expr2) = do
		typ1 <- checkAndGetType expr1
		typ2 <- checkAndGetType expr2
		isType Bool typ1 expr1
		isType Bool typ2 expr2

	checkType _ = do
		return ()

	getType (EVar ident) = do
		typ <- getVarType ident
		return typ

	getType (EArr arrAccess) = do
		typ <- getType arrAccess
		return typ

	getType (ENArr newArr) = do
		typ <- getType newArr
		return typ

	getType (ELitInt int) = do
		return Int

	getType (ELitTrue) = do
		return Bool

	getType (ELitFalse) = do
		return Bool

	getType (EApp ident exprs) = do
		typ <- getFunRetType ident
		return typ

	getType (EString string) = do
		return Str

	getType (Neg expr) = do
		return Int

	getType (Not expr) = do
		return Bool

	getType (EMul expr1 op expr2) = do
		return Int

	getType (EAdd expr1 op expr2) = do
		if op == Plus then do
			typ <- getType expr1
			return typ
		else return Int

	getType (ERel expr1 op expr2) = do
		return Bool

	getType (EAnd expr1 expr2) = do
		return Bool

	getType (EOr expr1 expr2) = do
		return Bool

instance TypeChecker ArrAccess where
	getType (ASimple ident expr) = do
		typ <- getVarType ident
		case typ of
			(Array typ) -> return typ
			_ -> fail $ (show ident) ++ "is not an array."

instance TypeChecker NewArr where
	getType (NewArr typ expr) = do
		return $ Array typ


isType :: (MonadState s m, Show a) => Type -> Type -> a -> m ()
isType expected actual struct = do
	if expected /= actual then
		fail $ "In expression (" ++ (show struct) ++ ") expected type : " ++ (show expected) ++ " mismaches with actual type : " ++ (show actual) ++ "."
	else do
		return ()	