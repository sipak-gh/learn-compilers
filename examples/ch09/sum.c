long sum(long n) {
    long total = 0;
    long i = 1;
    while (i <= n) {
        total = total + i;
        i = i + 1;
    }
    return total;
}
