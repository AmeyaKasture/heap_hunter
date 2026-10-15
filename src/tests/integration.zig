//! Integration tests that exercise the full parse -> index -> analysis flow
//! against real HPROF fixture files.
const std = @import("std");
const hprof = @import("../hprof.zig");
const Analysis = @import("../Analysis.zig");

fn loadIndex(allocator: std.mem.Allocator, relative_path: []const u8) !Analysis.Index {
    const io = std.testing.io;
    const dir = std.Io.Dir.cwd();
    var file = try dir.openFile(io, relative_path, .{});
    defer file.close(io);

    const file_len = try file.length(io);
    var mm = try std.Io.File.MemoryMap.create(io, file, .{
        .len = file_len,
        .protection = .{ .read = true, .write = false },
    });
    defer mm.destroy(io);

    var reader = try hprof.Reader.init(mm.memory);
    return try Analysis.buildIndex(allocator, &reader);
}

test "buildIndex finds heap-derived threads in real Java 21 dump" {
    // Full heap-dump fixtures create many short-lived index allocations. Keep
    // leak-detecting allocation in unit tests, but use the page allocator here
    // so this end-to-end test remains practical in the default test suite.
    const allocator = std.heap.page_allocator;
    var index = try loadIndex(allocator, "test_hprofs/heapforge.hprof");
    defer index.deinit();

    try std.testing.expectEqual(@as(u32, 6), index.threadCount());

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try Analysis.printThreads(&index, &buf);
    const output = buf.items;

    try std.testing.expect(std.mem.indexOf(u8, output, "Thread: main") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Reference Handler") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Finalizer") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Signal Dispatcher") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Notification Thread") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Common-Cleaner") != null);

    // main thread should have the stack trace from the heap dump.
    try std.testing.expect(std.mem.indexOf(u8, output, "HeapDumper.dump") != null);
}

test "heapforge_threads fixture is parsed and printed exactly" {
    const allocator = std.heap.page_allocator;
    var index = try loadIndex(allocator, "test_hprofs/heapforge_threads.hprof");
    defer index.deinit();

    try std.testing.expectEqual(@as(u32, 18), index.threadCount());

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try Analysis.printThreads(&index, &buf);

    const expected =
        \\Thread: Thread-0
        \\  State:    RUNNABLE
        \\  Priority: 5
        \\  Daemon:   false
        \\  TID:      28
        \\  Stack trace:
        \\    at com.example.heapforge.ThreadScenario.spinLoop(ThreadScenario.java:110)
        \\    at com.example.heapforge.ThreadScenario$$Lambda+0x00007f0c3c008b50.run(<?>)
        \\    at java.lang.Thread.runWith(Thread.java:1596)
        \\    at java.lang.Thread.run(Thread.java:1583)
        \\
        \\Thread: Thread-1
        \\  State:    RUNNABLE
        \\  Priority: 5
        \\  Daemon:   false
        \\  TID:      29
        \\  Stack trace:
        \\    at com.example.heapforge.ThreadScenario.spinLoop(ThreadScenario.java:110)
        \\    at com.example.heapforge.ThreadScenario$$Lambda+0x00007f0c3c008b50.run(<?>)
        \\    at java.lang.Thread.runWith(Thread.java:1596)
        \\    at java.lang.Thread.run(Thread.java:1583)
        \\
        \\Thread: Thread-2
        \\  State:    WAITING
        \\  Priority: 5
        \\  Daemon:   false
        \\  TID:      30
        \\  Stack trace:
        \\    at java.lang.Object.wait0(Object.java)
        \\    at java.lang.Object.wait(Object.java:366)
        \\    at java.lang.Object.wait(Object.java:339)
        \\    at com.example.heapforge.ThreadScenario.waitLoop(ThreadScenario.java:118)
        \\    at com.example.heapforge.ThreadScenario$$Lambda+0x00007f0c3c008d78.run(<?>)
        \\    at java.lang.Thread.runWith(Thread.java:1596)
        \\    at java.lang.Thread.run(Thread.java:1583)
        \\
        \\Thread: Thread-3
        \\  State:    TIMED_WAITING
        \\  Priority: 5
        \\  Daemon:   false
        \\  TID:      31
        \\  Stack trace:
        \\    at java.lang.Thread.sleep0(Thread.java)
        \\    at java.lang.Thread.sleep(Thread.java:509)
        \\    at com.example.heapforge.ThreadScenario.timedWaitLoop(ThreadScenario.java:130)
        \\    at com.example.heapforge.ThreadScenario$$Lambda+0x00007f0c3c008fa0.run(<?>)
        \\    at java.lang.Thread.runWith(Thread.java:1596)
        \\    at java.lang.Thread.run(Thread.java:1583)
        \\
        \\Thread: worker-pool-runnable-1
        \\  State:    RUNNABLE
        \\  Priority: 6
        \\  Daemon:   false
        \\  TID:      32
        \\  Stack trace:
        \\    at com.example.heapforge.ThreadScenario.spinLoop(ThreadScenario.java:110)
        \\    at com.example.heapforge.ThreadScenario$$Lambda+0x00007f0c3c0093f8.run(<?>)
        \\    at java.util.concurrent.Executors$RunnableAdapter.call(Executors.java:572)
        \\    at java.util.concurrent.FutureTask.run(FutureTask.java:317)
        \\    at java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1144)
        \\    at java.util.concurrent.ThreadPoolExecutor$Worker.run(ThreadPoolExecutor.java:642)
        \\    at java.lang.Thread.runWith(Thread.java:1596)
        \\    at java.lang.Thread.run(Thread.java:1583)
        \\
        \\Thread: worker-pool-runnable-2
        \\  State:    RUNNABLE
        \\  Priority: 6
        \\  Daemon:   false
        \\  TID:      33
        \\  Stack trace:
        \\    at com.example.heapforge.ThreadScenario.spinLoop(ThreadScenario.java:110)
        \\    at com.example.heapforge.ThreadScenario$$Lambda+0x00007f0c3c0093f8.run(<?>)
        \\    at java.util.concurrent.Executors$RunnableAdapter.call(Executors.java:572)
        \\    at java.util.concurrent.FutureTask.run(FutureTask.java:317)
        \\    at java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1144)
        \\    at java.util.concurrent.ThreadPoolExecutor$Worker.run(ThreadPoolExecutor.java:642)
        \\    at java.lang.Thread.runWith(Thread.java:1596)
        \\    at java.lang.Thread.run(Thread.java:1583)
        \\
        \\Thread: io-pool-waiting-1
        \\  State:    WAITING
        \\  Priority: 4
        \\  Daemon:   false
        \\  TID:      34
        \\  Stack trace:
        \\    at java.lang.Object.wait0(Object.java)
        \\    at java.lang.Object.wait(Object.java:366)
        \\    at java.lang.Object.wait(Object.java:339)
        \\    at com.example.heapforge.ThreadScenario.waitLoop(ThreadScenario.java:118)
        \\    at com.example.heapforge.ThreadScenario$$Lambda+0x00007f0c3c009620.run(<?>)
        \\    at java.util.concurrent.Executors$RunnableAdapter.call(Executors.java:572)
        \\    at java.util.concurrent.FutureTask.run(FutureTask.java:317)
        \\    at java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1144)
        \\    at java.util.concurrent.ThreadPoolExecutor$Worker.run(ThreadPoolExecutor.java:642)
        \\    at java.lang.Thread.runWith(Thread.java:1596)
        \\    at java.lang.Thread.run(Thread.java:1583)
        \\
        \\Thread: io-pool-waiting-2
        \\  State:    WAITING
        \\  Priority: 4
        \\  Daemon:   false
        \\  TID:      35
        \\  Stack trace:
        \\    at java.lang.Object.wait0(Object.java)
        \\    at java.lang.Object.wait(Object.java:366)
        \\    at java.lang.Object.wait(Object.java:339)
        \\    at com.example.heapforge.ThreadScenario.waitLoop(ThreadScenario.java:118)
        \\    at com.example.heapforge.ThreadScenario$$Lambda+0x00007f0c3c009620.run(<?>)
        \\    at java.util.concurrent.Executors$RunnableAdapter.call(Executors.java:572)
        \\    at java.util.concurrent.FutureTask.run(FutureTask.java:317)
        \\    at java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1144)
        \\    at java.util.concurrent.ThreadPoolExecutor$Worker.run(ThreadPoolExecutor.java:642)
        \\    at java.lang.Thread.runWith(Thread.java:1596)
        \\    at java.lang.Thread.run(Thread.java:1583)
        \\
        \\Thread: compute-pool-timed-1
        \\  State:    TIMED_WAITING
        \\  Priority: 7
        \\  Daemon:   false
        \\  TID:      36
        \\  Stack trace:
        \\    at java.lang.Thread.sleep0(Thread.java)
        \\    at java.lang.Thread.sleep(Thread.java:509)
        \\    at com.example.heapforge.ThreadScenario.timedWaitLoop(ThreadScenario.java:130)
        \\    at com.example.heapforge.ThreadScenario$$Lambda+0x00007f0c3c009848.run(<?>)
        \\    at java.util.concurrent.Executors$RunnableAdapter.call(Executors.java:572)
        \\    at java.util.concurrent.FutureTask.run(FutureTask.java:317)
        \\    at java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1144)
        \\    at java.util.concurrent.ThreadPoolExecutor$Worker.run(ThreadPoolExecutor.java:642)
        \\    at java.lang.Thread.runWith(Thread.java:1596)
        \\    at java.lang.Thread.run(Thread.java:1583)
        \\
        \\Thread: compute-pool-timed-2
        \\  State:    TIMED_WAITING
        \\  Priority: 7
        \\  Daemon:   false
        \\  TID:      37
        \\  Stack trace:
        \\    at java.lang.Thread.sleep0(Thread.java)
        \\    at java.lang.Thread.sleep(Thread.java:509)
        \\    at com.example.heapforge.ThreadScenario.timedWaitLoop(ThreadScenario.java:130)
        \\    at com.example.heapforge.ThreadScenario$$Lambda+0x00007f0c3c009848.run(<?>)
        \\    at java.util.concurrent.Executors$RunnableAdapter.call(Executors.java:572)
        \\    at java.util.concurrent.FutureTask.run(FutureTask.java:317)
        \\    at java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1144)
        \\    at java.util.concurrent.ThreadPoolExecutor$Worker.run(ThreadPoolExecutor.java:642)
        \\    at java.lang.Thread.runWith(Thread.java:1596)
        \\    at java.lang.Thread.run(Thread.java:1583)
        \\
        \\Thread: manual-high-priority
        \\  State:    RUNNABLE
        \\  Priority: 9
        \\  Daemon:   false
        \\  TID:      38
        \\  Stack trace:
        \\    at com.example.heapforge.ThreadScenario.spinLoop(ThreadScenario.java:110)
        \\    at com.example.heapforge.ThreadScenario$$Lambda+0x00007f0c3c009a70.run(<?>)
        \\    at java.lang.Thread.runWith(Thread.java:1596)
        \\    at java.lang.Thread.run(Thread.java:1583)
        \\
        \\Thread: manual-low-priority
        \\  State:    TIMED_WAITING
        \\  Priority: 2
        \\  Daemon:   false
        \\  TID:      39
        \\  Stack trace:
        \\    at java.lang.Thread.sleep0(Thread.java)
        \\    at java.lang.Thread.sleep(Thread.java:509)
        \\    at com.example.heapforge.ThreadScenario.timedWaitLoop(ThreadScenario.java:130)
        \\    at com.example.heapforge.ThreadScenario$$Lambda+0x00007f0c3c009c98.run(<?>)
        \\    at java.lang.Thread.runWith(Thread.java:1596)
        \\    at java.lang.Thread.run(Thread.java:1583)
        \\
        \\Thread: main
        \\  State:    RUNNABLE
        \\  Priority: 5
        \\  Daemon:   false
        \\  TID:      1
        \\  Stack trace:
        \\    at com.sun.management.internal.HotSpotDiagnostic.dumpHeap0(HotSpotDiagnostic.java)
        \\    at com.sun.management.internal.HotSpotDiagnostic.dumpHeap(HotSpotDiagnostic.java:70)
        \\    at java.lang.invoke.LambdaForm$DMH+0x00007f0c3c017000.invokeInterface(LambdaForm$DMH)
        \\    at java.lang.invoke.LambdaForm$MH+0x00007f0c3c019400.invoke(LambdaForm$MH)
        \\    at java.lang.invoke.LambdaForm$MH+0x00007f0c3c019800.invokeExact_MT(LambdaForm$MH)
        \\    at jdk.internal.reflect.DirectMethodHandleAccessor.invokeImpl(DirectMethodHandleAccessor.java:155)
        \\    at jdk.internal.reflect.DirectMethodHandleAccessor.invoke(DirectMethodHandleAccessor.java:103)
        \\    at java.lang.reflect.Method.invoke(Method.java:580)
        \\    at sun.reflect.misc.Trampoline.invoke(MethodUtil.java:64)
        \\    at java.lang.invoke.DirectMethodHandle$Holder.invokeStatic(DirectMethodHandle$Holder)
        \\    at java.lang.invoke.LambdaForm$MH+0x00007f0c3c016800.invoke(LambdaForm$MH)
        \\    at java.lang.invoke.LambdaForm$MH+0x00007f0c3c016c00.invokeExact_MT(LambdaForm$MH)
        \\    at jdk.internal.reflect.DirectMethodHandleAccessor.invokeImpl(DirectMethodHandleAccessor.java:156)
        \\    at jdk.internal.reflect.DirectMethodHandleAccessor.invoke(DirectMethodHandleAccessor.java:103)
        \\    at java.lang.reflect.Method.invoke(Method.java:580)
        \\    at sun.reflect.misc.MethodUtil.invoke(MethodUtil.java:97)
        \\    at com.sun.jmx.mbeanserver.ConvertingMethod.invokeWithOpenReturn(ConvertingMethod.java:193)
        \\    at com.sun.jmx.mbeanserver.ConvertingMethod.invokeWithOpenReturn(ConvertingMethod.java:175)
        \\    at com.sun.jmx.mbeanserver.MXBeanIntrospector.invokeM2(MXBeanIntrospector.java:115)
        \\    at com.sun.jmx.mbeanserver.MXBeanIntrospector.invokeM2(MXBeanIntrospector.java:52)
        \\    at com.sun.jmx.mbeanserver.MBeanIntrospector.invokeM(MBeanIntrospector.java:236)
        \\    at com.sun.jmx.mbeanserver.PerInterface.invoke(PerInterface.java:138)
        \\    at com.sun.jmx.mbeanserver.MBeanSupport.invoke(MBeanSupport.java:252)
        \\    at javax.management.StandardMBean.invoke(StandardMBean.java:405)
        \\    at com.sun.jmx.interceptor.DefaultMBeanServerInterceptor.invoke(DefaultMBeanServerInterceptor.java:803)
        \\    at com.sun.jmx.mbeanserver.JmxMBeanServer.invoke(JmxMBeanServer.java:802)
        \\    at com.sun.jmx.mbeanserver.MXBeanProxy$InvokeHandler.invoke(MXBeanProxy.java:150)
        \\    at com.sun.jmx.mbeanserver.MXBeanProxy.invoke(MXBeanProxy.java:167)
        \\    at javax.management.MBeanServerInvocationHandler.invoke(MBeanServerInvocationHandler.java:258)
        \\    at jdk.proxy1.$Proxy2.dumpHeap(<?>)
        \\    at com.example.heapforge.HeapDumper.dump(HeapDumper.java:27)
        \\    at com.example.heapforge.Main.handleDump(Main.java:132)
        \\    at com.example.heapforge.Main.handleThreadsDemo(Main.java:171)
        \\    at com.example.heapforge.Main.run(Main.java:45)
        \\    at com.example.heapforge.Main.main(Main.java:18)
        \\
        \\Thread: Reference Handler
        \\  State:    RUNNABLE
        \\  Priority: 10
        \\  Daemon:   true
        \\  TID:      9
        \\  Stack trace:
        \\    at java.lang.ref.Reference.waitForReferencePendingList(Reference.java)
        \\    at java.lang.ref.Reference.processPendingReferences(Reference.java:246)
        \\    at java.lang.ref.Reference$ReferenceHandler.run(Reference.java:208)
        \\
        \\Thread: Finalizer
        \\  State:    WAITING
        \\  Priority: 8
        \\  Daemon:   true
        \\  TID:      10
        \\  Stack trace:
        \\    at java.lang.Object.wait0(Object.java)
        \\    at java.lang.Object.wait(Object.java:366)
        \\    at java.lang.Object.wait(Object.java:339)
        \\    at java.lang.ref.NativeReferenceQueue.await(NativeReferenceQueue.java:48)
        \\    at java.lang.ref.ReferenceQueue.remove0(ReferenceQueue.java:158)
        \\    at java.lang.ref.NativeReferenceQueue.remove(NativeReferenceQueue.java:89)
        \\    at java.lang.ref.Finalizer$FinalizerThread.run(Finalizer.java:173)
        \\
        \\Thread: Signal Dispatcher
        \\  State:    RUNNABLE
        \\  Priority: 9
        \\  Daemon:   true
        \\  TID:      11
        \\  Stack trace:
        \\
        \\Thread: Notification Thread
        \\  State:    RUNNABLE
        \\  Priority: 9
        \\  Daemon:   true
        \\  TID:      26
        \\  Stack trace:
        \\
        \\Thread: Common-Cleaner
        \\  State:    TIMED_WAITING
        \\  Priority: 8
        \\  Daemon:   true
        \\  TID:      27
        \\  Stack trace:
        \\    at jdk.internal.misc.Unsafe.park(Unsafe.java)
        \\    at java.util.concurrent.locks.LockSupport.parkNanos(LockSupport.java:269)
        \\    at java.util.concurrent.locks.AbstractQueuedSynchronizer$ConditionObject.await(AbstractQueuedSynchronizer.java:1886)
        \\    at java.lang.ref.ReferenceQueue.await(ReferenceQueue.java:71)
        \\    at java.lang.ref.ReferenceQueue.remove0(ReferenceQueue.java:143)
        \\    at java.lang.ref.ReferenceQueue.remove(ReferenceQueue.java:218)
        \\    at jdk.internal.ref.CleanerImpl.run(CleanerImpl.java:140)
        \\    at java.lang.Thread.runWith(Thread.java:1596)
        \\    at java.lang.Thread.run(Thread.java:1583)
        \\    at jdk.internal.misc.InnocuousThread.run(InnocuousThread.java:186)
        \\
        \\
    ;

    try std.testing.expectEqualStrings(expected, buf.items);
}
