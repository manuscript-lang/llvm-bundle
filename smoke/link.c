/* End-to-end test for the shared LLVM library: linked against it (not loaded by path), it builds `i32 add(i32, i32)`
 * with the builder API, verifies and prints the module, compiles it to machine code with the ORC JIT and runs it:
 * add(2, 3) must return 5. The C API is declared by hand so the test needs no headers; LLVM-C is a stable C ABI.
 * Exits non-zero on any failure. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef void *Ref;
unsigned LLVMGetVersion(unsigned *, unsigned *, unsigned *);
Ref LLVMContextCreate(void);
Ref LLVMModuleCreateWithNameInContext(const char *, Ref);
void LLVMDisposeModule(Ref);
Ref LLVMInt32TypeInContext(Ref);
Ref LLVMFunctionType(Ref, Ref *, unsigned, int);
Ref LLVMAddFunction(Ref, const char *, Ref);
Ref LLVMAppendBasicBlockInContext(Ref, Ref, const char *);
Ref LLVMCreateBuilderInContext(Ref);
void LLVMDisposeBuilder(Ref);
void LLVMPositionBuilderAtEnd(Ref, Ref);
Ref LLVMGetParam(Ref, unsigned);
Ref LLVMBuildAdd(Ref, Ref, Ref, const char *);
Ref LLVMBuildRet(Ref, Ref);
int LLVMVerifyModule(Ref, int, char **);
char *LLVMPrintModuleToString(Ref);
void LLVMDisposeMessage(char *);
void LLVMDisposeErrorMessage(char *);
#if defined(__x86_64__) || defined(_M_X64)
void LLVMInitializeX86TargetInfo(void);
void LLVMInitializeX86Target(void);
void LLVMInitializeX86TargetMC(void);
void LLVMInitializeX86AsmPrinter(void);
#define INIT_TARGET() (LLVMInitializeX86TargetInfo(), LLVMInitializeX86Target(), LLVMInitializeX86TargetMC(), LLVMInitializeX86AsmPrinter())
#else
void LLVMInitializeAArch64TargetInfo(void);
void LLVMInitializeAArch64Target(void);
void LLVMInitializeAArch64TargetMC(void);
void LLVMInitializeAArch64AsmPrinter(void);
#define INIT_TARGET() (LLVMInitializeAArch64TargetInfo(), LLVMInitializeAArch64Target(), LLVMInitializeAArch64TargetMC(), LLVMInitializeAArch64AsmPrinter())
#endif
Ref LLVMOrcCreateNewThreadSafeContextFromLLVMContext(Ref);
void LLVMOrcDisposeThreadSafeContext(Ref);
Ref LLVMOrcCreateNewThreadSafeModule(Ref, Ref);
Ref LLVMOrcCreateLLJIT(Ref *, Ref);
Ref LLVMOrcLLJITGetMainJITDylib(Ref);
Ref LLVMOrcLLJITAddLLVMIRModule(Ref, Ref, Ref);
Ref LLVMOrcLLJITLookup(Ref, uint64_t *, const char *);
Ref LLVMOrcDisposeLLJIT(Ref);
char *LLVMGetErrorMessage(Ref);

static int fail(Ref error, const char *step) {
  char *message = LLVMGetErrorMessage(error);
  fprintf(stderr, "%s: %s\n", step, message);
  LLVMDisposeErrorMessage(message);
  return 1;
}

int main(void) {
  unsigned major = 0, minor = 0, patch = 0;
  LLVMGetVersion(&major, &minor, &patch);
  printf("LLVM %u.%u.%u\n", major, minor, patch);
  INIT_TARGET();
  Ref context = LLVMContextCreate();
  Ref safe_context = LLVMOrcCreateNewThreadSafeContextFromLLVMContext(context); /* takes ownership of the context */
  Ref module = LLVMModuleCreateWithNameInContext("link_test", context);
  Ref i32 = LLVMInt32TypeInContext(context);
  Ref params[2] = {i32, i32};
  Ref function = LLVMAddFunction(module, "add", LLVMFunctionType(i32, params, 2, 0));
  Ref builder = LLVMCreateBuilderInContext(context);
  LLVMPositionBuilderAtEnd(builder, LLVMAppendBasicBlockInContext(context, function, "entry"));
  LLVMBuildRet(builder, LLVMBuildAdd(builder, LLVMGetParam(function, 0), LLVMGetParam(function, 1), "sum"));
  char *error = NULL;
  if (LLVMVerifyModule(module, 2, &error)) {
    fprintf(stderr, "verify: %s\n", error ? error : "failed");
    return 1;
  }
  char *text = LLVMPrintModuleToString(module);
  printf("%s", text);
  int ok = strstr(text, "define i32 @add(") != NULL && strstr(text, "add i32 ") != NULL && strstr(text, "ret i32 ") != NULL;
  LLVMDisposeMessage(text);
  LLVMDisposeBuilder(builder);
  if (!ok) {
    fprintf(stderr, "unexpected IR\n");
    return 1;
  }
  /* The JIT owns the module from here on. */
  Ref jit = NULL, status;
  if ((status = LLVMOrcCreateLLJIT(&jit, NULL))) return fail(status, "create jit");
  if ((status = LLVMOrcLLJITAddLLVMIRModule(jit, LLVMOrcLLJITGetMainJITDylib(jit),
                                            LLVMOrcCreateNewThreadSafeModule(module, safe_context)))) {
    return fail(status, "add module");
  }
  LLVMOrcDisposeThreadSafeContext(safe_context);
  uint64_t address = 0;
  if ((status = LLVMOrcLLJITLookup(jit, &address, "add"))) return fail(status, "lookup add");
  int (*add)(int, int) = (int (*)(int, int))(uintptr_t)address;
  int sum = add(2, 3);
  printf("add(2, 3) = %d\n", sum);
  LLVMOrcDisposeLLJIT(jit);
  return sum == 5 ? 0 : 1;
}
