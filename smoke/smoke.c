/* Smoke test for the shared LLVM library asset: load it by path, parse text IR, optimize, emit an object in memory.
 * `smoke <library> <triple> <X86|AArch64>`. Prints exports it needs; exits non-zero on any failure. Declares the LLVM C
 * API itself (opaque pointers), as `ms` will, so it also proves no LLVM headers are needed to call the library. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
static void *load(const char *path) { return (void *)LoadLibraryExA(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH); }
static void *find(void *lib, const char *name) { return (void *)GetProcAddress((HMODULE)lib, name); }
#else
#include <dlfcn.h>
static void *load(const char *path) { return dlopen(path, RTLD_NOW | RTLD_LOCAL); }
static void *find(void *lib, const char *name) { return dlsym(lib, name); }
#endif

typedef void *P;
static void *lib;
static int failed;
static void *need(const char *name) {
  void *symbol = find(lib, name);
  if (!symbol) {
    fprintf(stderr, "missing export: %s\n", name);
    failed = 1;
  }
  return symbol;
}

/* A function with a debug location, so the object must carry line tables. */
static const char ir[] =
    "define i64 @add(i64 %a, i64 %b) !dbg !5 {\n"
    "  %r = add i64 %a, %b, !dbg !7\n"
    "  ret i64 %r, !dbg !7\n"
    "}\n"
    "!llvm.dbg.cu = !{!0}\n!llvm.module.flags = !{!3, !4}\n"
    "!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: \"smoke\", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug)\n"
    "!1 = !DIFile(filename: \"smoke.ms\", directory: \".\")\n"
    "!3 = !{i32 2, !\"Debug Info Version\", i32 3}\n!4 = !{i32 2, !\"Dwarf Version\", i32 4}\n"
    "!5 = distinct !DISubprogram(name: \"add\", scope: !1, file: !1, line: 1, type: !6, scopeLine: 1, spFlags: DISPFlagDefinition, unit: !0)\n"
    "!6 = !DISubroutineType(types: !{})\n"
    "!7 = !DILocation(line: 2, column: 3, scope: !5)\n";

int main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: smoke <library> <triple> <X86|AArch64>\n");
    return 2;
  }
  lib = load(argv[1]);
  if (!lib) {
    fprintf(stderr, "cannot load %s\n", argv[1]);
    return 1;
  }
  char init_info[64], init_target[64], init_mc[64], init_printer[64];
  snprintf(init_info, sizeof init_info, "LLVMInitialize%sTargetInfo", argv[3]);
  snprintf(init_target, sizeof init_target, "LLVMInitialize%sTarget", argv[3]);
  snprintf(init_mc, sizeof init_mc, "LLVMInitialize%sTargetMC", argv[3]);
  snprintf(init_printer, sizeof init_printer, "LLVMInitialize%sAsmPrinter", argv[3]);
  P (*context_create)(void) = need("LLVMContextCreate");
  P (*buffer_create)(const char *, size_t, const char *) = need("LLVMCreateMemoryBufferWithMemoryRangeCopy");
  int (*parse)(P, P, P *, char **) = need("LLVMParseIRInContext");
  void (*init[4])(void) = {need(init_info), need(init_target), need(init_mc), need(init_printer)};
  int (*target_from_triple)(const char *, P *, char **) = need("LLVMGetTargetFromTriple");
  P (*machine_create)(P, const char *, const char *, const char *, int, int, int) = need("LLVMCreateTargetMachine");
  P (*options_create)(void) = need("LLVMCreatePassBuilderOptions");
  P (*run_passes)(P, const char *, P, P) = need("LLVMRunPasses");
  int (*emit)(P, P, int, char **, P *) = need("LLVMTargetMachineEmitToMemoryBuffer");
  const char *(*buffer_start)(P) = need("LLVMGetBufferStart");
  size_t (*buffer_size)(P) = need("LLVMGetBufferSize");
  void (*fatal)(void (*)(const char *)) = need("LLVMInstallFatalErrorHandler");
  void (*version)(unsigned *, unsigned *, unsigned *) = need("LLVMGetVersion");
  if (failed) {
    return 1;
  }
  unsigned major = 0, minor = 0, patch = 0;
  version(&major, &minor, &patch);
  printf("library version %u.%u.%u\n", major, minor, patch);
  (void)fatal;
  for (int i = 0; i < 4; i++) {
    init[i]();
  }
  char *error = NULL;
  P context = context_create();
  P buffer = buffer_create(ir, sizeof ir - 1, "smoke");
  P module = NULL;
  if (parse(context, buffer, &module, &error)) {
    fprintf(stderr, "parse: %s\n", error);
    return 1;
  }
  P target = NULL;
  if (target_from_triple(argv[2], &target, &error)) {
    fprintf(stderr, "triple: %s\n", error);
    return 1;
  }
  P machine = machine_create(target, argv[2], "generic", "", 3, 2, 0);
  if (run_passes(module, "default<O3>", machine, options_create())) {
    fprintf(stderr, "passes failed\n");
    return 1;
  }
  P object = NULL;
  if (emit(machine, module, 1, &error, &object)) {
    fprintf(stderr, "emit: %s\n", error);
    return 1;
  }
  const char *bytes = buffer_start(object);
  size_t size = buffer_size(object);
  int has_lines = 0;
  for (size_t at = 0; at + 12 < size; at++) {
    if (!memcmp(bytes + at, "debug_line", 10)) {
      has_lines = 1;
      break;
    }
  }
  printf("object %zu bytes, line tables %s\n", size, has_lines ? "present" : "ABSENT");
  return size > 0 && has_lines ? 0 : 1;
}
