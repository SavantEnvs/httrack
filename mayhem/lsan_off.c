/* Leak detection off at build time: ASan and UBSan stay fully active. */
int __lsan_is_turned_off(void) { return 1; }
