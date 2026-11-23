/* Link test for the shared LLVM library: linked against it (not loaded by path), it builds `i32 add(i32, i32)` with the
 * builder API, verifies the module and checks the printed IR. The C API is declared by hand so the test needs no
 * headers; LLVM-C is a stable C ABI. Exits non-zero on any failure. */
#include <stdio.h>
#include <string.h>

typedef void *Ref;
unsigned LLVMGetVersion(unsigned *, unsigned *, unsigned *);
Ref LLVMContextCreate(void);
void LLVMContextDispose(Ref);
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

int main(void) {
  unsigned major = 0, minor = 0, patch = 0;
  LLVMGetVersion(&major, &minor, &patch);
  printf("LLVM %u.%u.%u\n", major, minor, patch);
  Ref context = LLVMContextCreate();
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
  LLVMDisposeModule(module);
  LLVMContextDispose(context);
  if (!ok) {
    fprintf(stderr, "unexpected IR\n");
    return 1;
  }
  return 0;
}
