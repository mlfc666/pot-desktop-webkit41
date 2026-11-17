// Debian 13: WebKitGTK 4.1 links libsoup3, which aborts when libsoup2 is loaded
// into the same process. Nothing in this graph calls soup2 anymore, so the probe
// (and the -lsoup-2.4 it advertises) is dropped on purpose.
fn main() {}
