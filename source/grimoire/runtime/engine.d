/** 
 * Copyright: Enalye
 * License: Zlib
 * Authors: Enalye
 */
module grimoire.runtime.engine;

import std.string;
import std.array;
import std.conv;
import std.math;
import std.algorithm.mutation : swapAt;
import std.typecons : Nullable;

import grimoire.compiler;
import grimoire.assembly;
import grimoire.assembly.debug_info;

import grimoire.runtime.context;
import grimoire.runtime.array;
import grimoire.runtime.object;
import grimoire.runtime.channel;
import grimoire.runtime.indexedarray;
import grimoire.runtime.call;

/**
Grimoire's virtual machine.
*/
class GrEngine {
    private {
        /// Bytecode.
        GrBytecode _bytecode;

        /// Global integral variables.
        int[] _iglobals;
        /// Global float variables.
        float[] _fglobals;
        /// Global string variables.
        string[] _sglobals;
        /// Global object variables.
        void*[] _oglobals;

        /// Global integral stack.
        int[] _iglobalStackIn, _iglobalStackOut;
        /// Global float stack.
        float[] _fglobalStackIn, _fglobalStackOut;
        /// Global string stack.
        string[] _sglobalStackIn, _sglobalStackOut;
        /// Global object stack.
        void*[] _oglobalStackIn, _oglobalStackOut;

        /// Context array.
        DynamicIndexedArray!GrContext _contexts, _contextsToSpawn;

        /// Global panic state.
        /// It means that the throwing context didn't handle the exception.
        bool _isPanicking;
        /// Unhandled panic message.
        string _panicMessage;

        /// Extra type compiler information.
        string _meta;

        /// Primitives.
        GrCallback[] _callbacks;
        /// Ditto
        GrCall[] _calls;
    }

    /// External way of stopping the VM.
    shared bool isRunning = true;

    @property {
        /// Check if there is a coroutine currently running.
        bool hasCoroutines() const {
            return (_contexts.length + _contextsToSpawn.length) > 0uL;
        }

        /// Whether the whole VM has panicked, true if an unhandled error occurred.
        bool isPanicking() const {
            return _isPanicking;
        }

        /// The unhandled error message.
        string panicMessage() const {
            return _panicMessage;
        }

        /// Extra type compiler information.
        string meta() const {
            return _meta;
        }
        /// Ditto
        string meta(string newMeta) {
            return _meta = newMeta;
        }
    }

    /// Default.
    this() {
    }

    private void initialize() {
        _contexts = new DynamicIndexedArray!GrContext;
        _contextsToSpawn = new DynamicIndexedArray!GrContext;
    }

    /// Add a new library to the runtime.
    /// ___
    /// It must be called before loading the bytecode.
    /// It should be loading the same library as the compiler
    /// and in the same order.
    final void addLibrary(GrLibrary library) {
        _callbacks ~= library._callbacks;
    }

    /// Load the bytecode.
    final void load(GrBytecode bytecode) {
        initialize();
        _bytecode = bytecode;
        _iglobals = new int[bytecode.iglobalsCount];
        _fglobals = new float[bytecode.fglobalsCount];
        _sglobals = new string[bytecode.sglobalsCount];
        _oglobals = new void*[bytecode.oglobalsCount];

        // Setup the primitives
        for (int i; i < bytecode.primitives.length; ++i) {
            if (bytecode.primitives[i].index > _callbacks.length)
                throw new Exception("callback index out of bounds");
            _calls ~= new GrCall(_callbacks[bytecode.primitives[i].index], bytecode.primitives[i]);
        }
    }

    /**
	Create the main context.
	You must call this function before running the vm.
	---
	main {
		printl("Hello World !");
	}
	---
    */
    void spawn() {
        _contexts.push(new GrContext(this));
    }

    /**
	Checks whether an event exists. \
	`eventName` must be the mangled name of the event.
	*/
    bool hasEvent(string eventName) {
        return (eventName in _bytecode.events) !is null;
    }

    /**
	Spawn a new coroutine registered as an event. \
	`eventName` must be the mangled name of the event.
	---
	event mycoroutine() {
		printl("mycoroutine was created !");
	}
	---
	*/
    GrContext spawnEvent(string eventName) {
        const auto event = eventName in _bytecode.events;
        if (event is null)
            throw new Exception("No event \'" ~ eventName ~ "\' in script");
        GrContext context = new GrContext(this);
        context.pc = *event;
        _contextsToSpawn.push(context);
        return context;
    }

    package(grimoire) void pushContext(GrContext context) {
        _contextsToSpawn.push(context);
    }

    /**
    Captures an unhandled error and kill the VM.
    */
    void panic() {
        _contexts.reset();
    }

    /**
    Generates a developer friendly stacktrace
    */
    string[] generateDebugStackTrace(GrContext context) {
        import std.format : format;
        string[] trace = [];
        int frameCounter = 1;
        foreach (GrStackFrame frame; context.callStack[1..$]) {
            auto maybeFunc = getFunctionInfo(frame.retPosition);
            if(maybeFunc.isNull) {
                trace ~= format!"#%d\tUnknown Function\tinstr %d (??/??)"(
                    frameCounter,
                    frame.retPosition
                );
            } else {
                trace ~= format!"#%d\t%s\tinstr %d (%d/%d)"(
                    frameCounter, 
                    maybeFunc.get.functionName,
                    frame.retPosition,
                    frame.retPosition - maybeFunc.get.bytecodePosition,
                    maybeFunc.get.length,    
                );
            }
            frameCounter++;
        }

        
        auto maybeFunc = getFunctionInfo(context.pc);
        if(maybeFunc.isNull) {
            trace ~= format!"#%d\tUnknown Function\tinstr %d (??/??)"(
                frameCounter,
                context.pc,
            );
        } else {
            trace ~= format!"#%d\t%s\tinstr %d (%d/%d)"(
                frameCounter, 
                maybeFunc.get.functionName,
                context.pc,
                context.pc - maybeFunc.get.bytecodePosition,
                maybeFunc.get.length,    
            );
        }

        return trace;
    }

    /**
    Immediately prints a stacktrace to standard output
    */
    void printDebugStackTrace(GrContext context) {
        import std.stdio : writeln;
        foreach(string line; generateDebugStackTrace(context)) {
            writeln(line);
        }
    }

    /**
    Tries to resolve a function from a position in the bytecode
    */
    private Nullable!(GrFunctionInfo) getFunctionInfo(uint position) {
        Nullable!(GrFunctionInfo) bestInfo;
        foreach(const GrDebugInfo _info; _bytecode.debugInfo) {
            if(_info.classinfo == GrFunctionInfo.classinfo) {
                auto info = cast(GrFunctionInfo) _info;
                if(info.bytecodePosition <= position && info.bytecodePosition + info.length > position)
                {
                    if(bestInfo.isNull) {
                        bestInfo = info;
                    } else {
                        if(bestInfo.get.length > info.length) {
                            bestInfo = info;
                        }
                    }
                }
            }
        }
        return bestInfo;
    }

    /**
	Raise an error message and attempt to recover from it. \
	The error is raised inside a coroutine. \
	___
	For each function it unwinds, it'll search for a `try/catch` that captures it. \
	If none is found, it'll execute every `defer` statements inside the function and
	do the same for the next function in the callstack.
	___
	If nothing catches the error inside the coroutine, the VM enters in a panic state. \
	Every coroutines will then execute their `defer` statements and be killed.
	*/
    void raise(GrContext context, string message) {
        if (context.isPanicking)
            return;
        //Error message.
        _sglobalStackIn ~= message;

        printDebugStackTrace(context);

        //We indicate that the coroutine is in a panic state until a catch is found.
        context.isPanicking = true;

        context.pc = cast(uint)(cast(int) _bytecode.opcodes.length - 1);


        /+
        //Exception handler found in the current function, just jump.
        if (context.callStack[context.stackPos].exceptionHandlers.length) {
            context.pc = context.callStack[context.stackPos].exceptionHandlers[$ - 1];
        }
        //No exception handler in the current function, unwinding the deferred code, then return.

        //Check for deferred calls as we will exit the current function.
        else if (context.callStack[context.stackPos].deferStack.length) {
            //Pop the last defer and run it.
            context.pc = context.callStack[context.stackPos].deferStack[$ - 1];
            context.callStack[context.stackPos].deferStack.length--;
            //The search for an exception handler will be done by Unwind after all defer
            //has been called for this function.
        }
        else if (context.stackPos) {
            //Then returns to the last context, raise will be run again.
            context.stackPos--;
            context.ilocalsPos -= context.callStack[context.stackPos].ilocalStackSize;
            context.flocalsPos -= context.callStack[context.stackPos].flocalStackSize;
            context.slocalsPos -= context.callStack[context.stackPos].slocalStackSize;
            context.olocalsPos -= context.callStack[context.stackPos].olocalStackSize;

            if (_isDebug)
                _debugProfileEnd();
        }
        else {
            //Kill the others.
            foreach (coroutine; _contexts) {
                coroutine.pc = cast(uint)(cast(int) _bytecode.opcodes.length - 1);
                coroutine.isKilled = true;
            }
            _contextsToSpawn.reset();

            //The VM is now panicking.
            _isPanicking = true;
            _panicMessage = _sglobalStackIn[$ - 1];
            _sglobalStackIn.length--;
        }+/
    }

    /**
	Marks each coroutine as killed and prevents any new coroutine from spawning.
	*/
    private void killAll() {
        foreach (coroutine; _contexts) {
            coroutine.pc = cast(uint)(cast(int) _bytecode.opcodes.length - 1);
            coroutine.isKilled = true;
        }
        _contextsToSpawn.reset();
    }

    alias getBoolVariable = getVariable!bool;
    alias getIntVariable = getVariable!int;
    alias getFloatVariable = getVariable!float;
    alias getStringVariable = getVariable!string;
    alias getPtrVariable = getVariable!(void*);

    GrObject getObjectVariable(string name) {
        return cast(GrObject) getVariable!(void*)(name);
    }

    GrIntArray getIntArrayVariable(string name) {
        return cast(GrIntArray) getVariable!(void*)(name);
    }

    GrFloatArray getFloatArrayVariable(string name) {
        return cast(GrFloatArray) getVariable!(void*)(name);
    }

    GrStringArray getStringArrayVariable(string name) {
        return cast(GrStringArray) getVariable!(void*)(name);
    }

    GrObjectArray getObjectArrayVariable(string name) {
        return cast(GrObjectArray) getVariable!(void*)(name);
    }

    GrIntChannel getIntChannelVariable(string name) {
        return cast(GrIntChannel) getVariable!(void*)(name);
    }

    GrFloatChannel getFloatChannelVariable(string name) {
        return cast(GrFloatChannel) getVariable!(void*)(name);
    }

    GrStringChannel getStringChannelVariable(string name) {
        return cast(GrStringChannel) getVariable!(void*)(name);
    }

    GrObjectChannel getObjectChannelVariable(string name) {
        return cast(GrObjectChannel) getVariable!(void*)(name);
    }

    T getEnumVariable(T)(string name) {
        return cast(T) getVariable!int(name);
    }

    T getForeignVariable(T)(string name) {
        // We cast to object first to avoid a crash when casting to a parent class
        return cast(T) cast(Object) getVariable!(void*)(name);
    }

    private T getVariable(T)(string name) {
        const auto variable = name in _bytecode.globalReferences;
        if (variable is null)
            throw new Exception("no global variable `" ~ name ~ "` defined");
        static if (is(T == int)) {
            if ((variable.typeMask & 0x1) == 0)
                throw new Exception("variable `" ~ name ~ "` is not an int");
            return _iglobals[variable.index];
        }
        else static if (is(T == bool)) {
            if ((variable.typeMask & 0x1) == 0)
                throw new Exception("variable `" ~ name ~ "` is not an int");
            return _iglobals[variable.index] > 0;
        }
        else static if (is(T == float)) {
            if ((variable.typeMask & 0x2) == 0)
                throw new Exception("variable `" ~ name ~ "` is not a float");
            return _fglobals[variable.index];
        }
        else static if (is(T == string)) {
            if ((variable.typeMask & 0x4) == 0)
                throw new Exception("variable `" ~ name ~ "` is not a string");
            return _sglobals[variable.index];
        }
        else static if (is(T == void*)) {
            if ((variable.typeMask & 0x8) == 0)
                throw new Exception("variable `" ~ name ~ "` is not an object");
            return _oglobals[variable.index];
        }
    }

    alias setBoolVariable = setVariable!bool;
    alias setIntVariable = setVariable!int;
    alias setFloatVariable = setVariable!float;
    alias setStringVariable = setVariable!string;
    alias setPtrVariable = setVariable!(void*);

    void setObjectVariable(string name, GrObject value) {
        setVariable!(void*)(name, cast(void*) value);
    }

    void setIntArrayVariable(string name, GrIntArray value) {
        setVariable!(void*)(name, cast(void*) value);
    }

    void setFloatArrayVariable(string name, GrFloatArray value) {
        setVariable!(void*)(name, cast(void*) value);
    }

    void setStringArrayVariable(string name, GrStringArray value) {
        setVariable!(void*)(name, cast(void*) value);
    }

    void setObjectArrayVariable(string name, GrObjectArray value) {
        setVariable!(void*)(name, cast(void*) value);
    }

    void setIntChannelVariable(string name, GrIntChannel value) {
        setVariable!(void*)(name, cast(void*) value);
    }

    void setFloatChannelVariable(string name, GrFloatChannel value) {
        setVariable!(void*)(name, cast(void*) value);
    }

    void setStringChannelVariable(string name, GrStringChannel value) {
        setVariable!(void*)(name, cast(void*) value);
    }

    void setObjectChannelVariable(string name, GrObjectChannel value) {
        setVariable!(void*)(name, cast(void*) value);
    }

    void setEnumVariable(T)(string name, T value) {
        setVariable!int(name, cast(int) value);
    }

    void setForeignVariable(T)(string name, T value) {
        setVariable!(void*)(name, cast(void*) value);
    }

    private void setVariable(T)(string name, T value) {
        const auto variable = name in _bytecode.globalReferences;
        if (variable is null)
            throw new Exception("no global variable `" ~ name ~ "` defined");
        static if (is(T == int)) {
            if ((variable.typeMask & 0x1) == 0)
                throw new Exception("variable `" ~ name ~ "` is not an int");
            _iglobals[variable.index] = value;
        }
        else static if (is(T == bool)) {
            if ((variable.typeMask & 0x1) == 0)
                throw new Exception("variable `" ~ name ~ "` is not an int");
            _iglobals[variable.index] = value;
        }
        else static if (is(T == float)) {
            if ((variable.typeMask & 0x2) == 0)
                throw new Exception("variable `" ~ name ~ "` is not a float");
            _fglobals[variable.index] = value;
        }
        else static if (is(T == string)) {
            if ((variable.typeMask & 0x4) == 0)
                throw new Exception("variable `" ~ name ~ "` is not a string");
            _sglobals[variable.index] = value;
        }
        else static if (is(T == void*)) {
            if ((variable.typeMask & 0x8) == 0)
                throw new Exception("variable `" ~ name ~ "` is not an object");
            _oglobals[variable.index] = value;
        }
    }

    /// Run the vm until all the contexts are finished or in yield.
    void process() {
        if (_contextsToSpawn.length) {
            for (int index = cast(int) _contextsToSpawn.length - 1; index >= 0; index--)
                _contexts.push(_contextsToSpawn[index]);
            _contextsToSpawn.reset();
            import std.algorithm.mutation : swap;

            swap(_iglobalStackIn, _iglobalStackOut);
            swap(_fglobalStackIn, _fglobalStackOut);
            swap(_sglobalStackIn, _sglobalStackOut);
            swap(_oglobalStackIn, _oglobalStackOut);
        }
        contextsLabel: for (uint index = 0u; index < _contexts.length; index++) {
            GrContext context = _contexts.data[index];
            while (isRunning) {
                const uint opcode = _bytecode.opcodes[context.pc];
                final switch (opcode & 0xFF) with (GrOpcode) {
                case nop:
                    context.pc++;
                    break;
                case raise_:
                    if (!context.isPanicking) {
                        //Error message.
                        _sglobalStackIn ~= context.sstack[context.sstackPos];
                        context.sstackPos--;

                        //We indicate that the coroutine is in a panic state until a catch is found.
                        context.isPanicking = true;
                    }

                    //Exception handler found in the current function, just jump.
                    if (context.callStack[context.stackPos].exceptionHandlers.length) {
                        context.pc = context.callStack[context.stackPos].exceptionHandlers[$ - 1];
                    }
                    //No exception handler in the current function, unwinding the deferred code, then return.

                    //Check for deferred calls as we will exit the current function.
                    else if (context.callStack[context.stackPos].deferStack.length) {
                        //Pop the last defer and run it.
                        context.pc = context.callStack[context.stackPos].deferStack[$ - 1];
                        context.callStack[context.stackPos].deferStack.length--;
                        //The search for an exception handler will be done by Unwind after all defer
                        //has been called for this function.
                    }
                    else if (context.stackPos) {
                        //Then returns to the last context, raise will be run again.
                        context.stackPos--;
                        context.ilocalsPos -= context.callStack[context.stackPos].ilocalStackSize;
                        context.flocalsPos -= context.callStack[context.stackPos].flocalStackSize;
                        context.slocalsPos -= context.callStack[context.stackPos].slocalStackSize;
                        context.olocalsPos -= context.callStack[context.stackPos].olocalStackSize;

                        if (_isDebug)
                            _debugProfileEnd();
                    }
                    else {
                        //Kill the others.
                        killAll();

                        //The VM is now panicking.
                        _isPanicking = true;
                        _panicMessage = _sglobalStackIn[$ - 1];
                        _sglobalStackIn.length--;

                        //Every deferred call has been executed, now die.
                        _contexts.markInternalForRemoval(index);
                        continue contextsLabel;
                    }
                    break;
                case try_:
                    context.callStack[context.stackPos].exceptionHandlers ~= context.pc + grGetInstructionSignedValue(
                            opcode);
                    context.pc++;
                    break;
                case catch_:
                    context.callStack[context.stackPos].exceptionHandlers.length--;
                    if (context.isPanicking) {
                        context.isPanicking = false;
                        context.pc++;
                    }
                    else {
                        context.pc += grGetInstructionSignedValue(opcode);
                    }
                    break;
                case task:
                    GrContext newCoro = new GrContext(this);
                    newCoro.pc = grGetInstructionUnsignedValue(opcode);
                    _contextsToSpawn.push(newCoro);
                    context.pc++;
                    break;
                case anonymousTask:
                    GrContext newCoro = new GrContext(this);
                    newCoro.pc = context.istack[context.istackPos];
                    context.istackPos--;
                    _contextsToSpawn.push(newCoro);
                    context.pc++;
                    break;
                case kill_:
                    //Check for deferred calls.
                    if (context.callStack[context.stackPos].deferStack.length) {
                        //Pop the last defer and run it.
                        context.pc = context.callStack[context.stackPos].deferStack[$ - 1];
                        context.callStack[context.stackPos].deferStack.length--;

                        //Flag as killed so the entire stack will be unwinded.
                        context.isKilled = true;
                    }
                    else if (context.stackPos) {
                        //Then returns to the last context.
                        context.stackPos--;
                        context.pc = context.callStack[context.stackPos].retPosition;
                        context.ilocalsPos -= context.callStack[context.stackPos].ilocalStackSize;
                        context.flocalsPos -= context.callStack[context.stackPos].flocalStackSize;
                        context.slocalsPos -= context.callStack[context.stackPos].slocalStackSize;
                        context.olocalsPos -= context.callStack[context.stackPos].olocalStackSize;

                        //Flag as killed so the entire stack will be unwinded.
                        context.isKilled = true;
                    }
                    else {
                        //No need to flag if the call stack is empty without any deferred statement.
                        _contexts.markInternalForRemoval(index);
                        continue contextsLabel;
                    }
                    break;
                case killAll_:
                    killAll();
                    continue contextsLabel;
                case yield:
                    context.pc++;
                    continue contextsLabel;
                case new_:
                    context.ostackPos++;
                    if (context.ostackPos == context.ostack.length)
                        context.ostack.length *= 2;
                    context.ostack[context.ostackPos] = cast(void*) new GrObject(
                            _bytecode.classes[grGetInstructionUnsignedValue(opcode)]);
                    context.pc++;
                    break;
                case channel_int:
                    context.ostackPos++;
                    if (context.ostackPos == context.ostack.length)
                        context.ostack.length *= 2;
                    context.ostack[context.ostackPos] = cast(void*) new GrIntChannel(
                            grGetInstructionUnsignedValue(opcode));
                    context.pc++;
                    break;
                case channel_float:
                    context.ostackPos++;
                    if (context.ostackPos == context.ostack.length)
                        context.ostack.length *= 2;
                    context.ostack[context.ostackPos] = cast(void*) new GrFloatChannel(
                            grGetInstructionUnsignedValue(opcode));
                    context.pc++;
                    break;
                case channel_string:
                    context.ostackPos++;
                    if (context.ostackPos == context.ostack.length)
                        context.ostack.length *= 2;
                    context.ostack[context.ostackPos] = cast(void*) new GrStringChannel(
                            grGetInstructionUnsignedValue(opcode));
                    context.pc++;
                    break;
                case channel_object:
                    context.ostackPos++;
                    if (context.ostackPos == context.ostack.length)
                        context.ostack.length *= 2;
                    context.ostack[context.ostackPos] = cast(void*) new GrObjectChannel(
                            grGetInstructionUnsignedValue(opcode));
                    context.pc++;
                    break;
                case send_int:
                    GrIntChannel chan = cast(GrIntChannel) context.ostack[context.ostackPos];
                    if (!chan.isOwned) {
                        if (context.isEvaluatingChannel) {
                            context.restoreState();
                            context.isLocked = true;
                            context.isEvaluatingChannel = false;
                            context.pc = context.selectPositionJump;
                        }
                        else {
                            context.istackPos--;
                            context.ostackPos--;
                            raise(context, "ChannelError");
                        }
                    }
                    else if (chan.canSend) {
                        context.isLocked = false;
                        chan.send(context.istack[context.istackPos]);
                        context.ostackPos--;
                        context.pc++;
                    }
                    else {
                        context.isLocked = true;
                        if (context.isEvaluatingChannel) {
                            context.restoreState();
                            context.isEvaluatingChannel = false;
                            context.pc = context.selectPositionJump;
                        }
                        else
                            continue contextsLabel;
                    }
                    break;
                case send_float:
                    GrFloatChannel chan = cast(GrFloatChannel) context.ostack[context.ostackPos];
                    if (!chan.isOwned) {
                        if (context.isEvaluatingChannel) {
                            context.restoreState();
                            context.isLocked = true;
                            context.isEvaluatingChannel = false;
                            context.pc = context.selectPositionJump;
                        }
                        else {
                            context.fstackPos--;
                            context.ostackPos--;
                            raise(context, "ChannelError");
                        }
                    }
                    else if (chan.canSend) {
                        context.isLocked = false;
                        chan.send(context.fstack[context.fstackPos]);
                        context.ostackPos--;
                        context.pc++;
                    }
                    else {
                        context.isLocked = true;
                        if (context.isEvaluatingChannel) {
                            context.restoreState();
                            context.isEvaluatingChannel = false;
                            context.pc = context.selectPositionJump;
                        }
                        else
                            continue contextsLabel;
                    }
                    break;
                case send_string:
                    GrStringChannel chan = cast(GrStringChannel) context.ostack[context.ostackPos];
                    if (!chan.isOwned) {
                        if (context.isEvaluatingChannel) {
                            context.restoreState();
                            context.isLocked = true;
                            context.isEvaluatingChannel = false;
                            context.pc = context.selectPositionJump;
                        }
                        else {
                            context.sstackPos--;
                            context.ostackPos--;
                            raise(context, "ChannelError");
                        }
                    }
                    else if (chan.canSend) {
                        context.isLocked = false;
                        chan.send(context.sstack[context.sstackPos]);
                        context.ostackPos--;
                        context.pc++;
                    }
                    else {
                        context.isLocked = true;
                        if (context.isEvaluatingChannel) {
                            context.restoreState();
                            context.isEvaluatingChannel = false;
                            context.pc = context.selectPositionJump;
                        }
                        else
                            continue contextsLabel;
                    }
                    break;
                case send_object:
                    GrObjectChannel chan = cast(GrObjectChannel) context
                        .ostack[context.ostackPos - 1];
                    if (!chan.isOwned) {
                        if (context.isEvaluatingChannel) {
                            context.restoreState();
                            context.isLocked = true;
                            context.isEvaluatingChannel = false;
                            context.pc = context.selectPositionJump;
                        }
                        else {
                            context.ostackPos -= 2;
                            raise(context, "ChannelError");
                        }
                    }
                    else if (chan.canSend) {
                        context.isLocked = false;
                        chan.send(context.ostack[context.ostackPos]);
                        context.ostack[context.ostackPos - 1] = context.ostack[context.ostackPos];
                        context.ostackPos--;
                        context.pc++;
                    }
                    else {
                        context.isLocked = true;
                        if (context.isEvaluatingChannel) {
                            context.restoreState();
                            context.isEvaluatingChannel = false;
                            context.pc = context.selectPositionJump;
                        }
                        else
                            continue contextsLabel;
                    }
                    break;
                case receive_int:
                    GrIntChannel chan = cast(GrIntChannel) context.ostack[context.ostackPos];
                    if (!chan.isOwned) {
                        if (context.isEvaluatingChannel) {
                            context.restoreState();
                            context.isLocked = true;
                            context.isEvaluatingChannel = false;
                            context.pc = context.selectPositionJump;
                        }
                        else {
                            context.ostackPos--;
                            raise(context, "ChannelError");
                        }
                    }
                    else if (chan.canReceive) {
                        context.isLocked = false;
                        context.istackPos++;
                        if (context.istackPos == context.istack.length)
                            context.istack.length *= 2;
                        context.istack[context.istackPos] = chan.receive();
                        context.ostackPos--;
                        context.pc++;
                    }
                    else {
                        chan.setReceiverReady();
                        context.isLocked = true;
                        if (context.isEvaluatingChannel) {
                            context.restoreState();
                            context.isEvaluatingChannel = false;
                            context.pc = context.selectPositionJump;
                        }
                        else
                            continue contextsLabel;
                    }
                    break;
                case receive_float:
                    GrFloatChannel chan = cast(GrFloatChannel) context.ostack[context.ostackPos];
                    if (!chan.isOwned) {
                        if (context.isEvaluatingChannel) {
                            context.restoreState();
                            context.isLocked = true;
                            context.isEvaluatingChannel = false;
                            context.pc = context.selectPositionJump;
                        }
                        else {
                            context.ostackPos--;
                            raise(context, "ChannelError");
                        }
                    }
                    else if (chan.canReceive) {
                        context.isLocked = false;
                        context.fstackPos++;
                        if (context.fstackPos == context.fstack.length)
                            context.fstack.length *= 2;
                        context.fstack[context.fstackPos] = chan.receive();
                        context.ostackPos--;
                        context.pc++;
                    }
                    else {
                        chan.setReceiverReady();
                        context.isLocked = true;
                        if (context.isEvaluatingChannel) {
                            context.restoreState();
                            context.isEvaluatingChannel = false;
                            context.pc = context.selectPositionJump;
                        }
                        else
                            continue contextsLabel;
                    }
                    break;
                case receive_string:
                    GrStringChannel chan = cast(GrStringChannel) context.ostack[context.ostackPos];
                    if (!chan.isOwned) {
                        if (context.isEvaluatingChannel) {
                            context.restoreState();
                            context.isLocked = true;
                            context.isEvaluatingChannel = false;
                            context.pc = context.selectPositionJump;
                        }
                        else {
                            context.ostackPos--;
                            raise(context, "ChannelError");
                        }
                    }
                    else if (chan.canReceive) {
                        context.isLocked = false;
                        context.sstackPos++;
                        if (context.sstackPos == context.sstack.length)
                            context.sstack.length *= 2;
                        context.sstack[context.sstackPos] = chan.receive();
                        context.ostackPos--;
                        context.pc++;
                    }
                    else {
                        chan.setReceiverReady();
                        context.isLocked = true;
                        if (context.isEvaluatingChannel) {
                            context.restoreState();
                            context.isEvaluatingChannel = false;
                            context.pc = context.selectPositionJump;
                        }
                        else
                            continue contextsLabel;
                    }
                    break;
                case receive_object:
                    GrObjectChannel chan = cast(GrObjectChannel) context.ostack[context.ostackPos];
                    if (!chan.isOwned) {
                        if (context.isEvaluatingChannel) {
                            context.restoreState();
                            context.isLocked = true;
                            context.isEvaluatingChannel = false;
                            context.pc = context.selectPositionJump;
                        }
                        else {
                            context.ostackPos--;
                            raise(context, "ChannelError");
                        }
                    }
                    else if (chan.canReceive) {
                        context.isLocked = false;
                        context.ostack[context.ostackPos] = chan.receive();
                        context.pc++;
                    }
                    else {
                        chan.setReceiverReady();
                        context.isLocked = true;
                        if (context.isEvaluatingChannel) {
                            context.restoreState();
                            context.isEvaluatingChannel = false;
                            context.pc = context.selectPositionJump;
                        }
                        else
                            continue contextsLabel;
                    }
                    break;
                case startSelectChannel:
                    context.pushState();
                    context.pc++;
                    break;
                case endSelectChannel:
                    context.popState();
                    context.pc++;
                    break;
                case tryChannel:
                    if (context.isEvaluatingChannel)
                        raise(context, "SelectError");
                    context.isEvaluatingChannel = true;
                    context.selectPositionJump = context.pc + grGetInstructionSignedValue(opcode);
                    context.pc++;
                    break;
                case checkChannel:
                    if (!context.isEvaluatingChannel)
                        raise(context, "SelectError");
                    context.isEvaluatingChannel = false;
                    context.restoreState();
                    context.pc++;
                    break;
                case shiftStack_int:
                    context.istackPos += grGetInstructionSignedValue(opcode);
                    context.pc++;
                    break;
                case shiftStack_float:
                    context.fstackPos += grGetInstructionSignedValue(opcode);
                    context.pc++;
                    break;
                case shiftStack_string:
                    context.sstackPos += grGetInstructionSignedValue(opcode);
                    context.pc++;
                    break;
                case shiftStack_object:
                    context.ostackPos += grGetInstructionSignedValue(opcode);
                    context.pc++;
                    break;
                case localStore_int:
                    context.ilocals[context.ilocalsPos + grGetInstructionUnsignedValue(
                                opcode)] = context.istack[context.istackPos];
                    context.istackPos--;
                    context.pc++;
                    break;
                case localStore_float:
                    context.flocals[context.flocalsPos + grGetInstructionUnsignedValue(
                                opcode)] = context.fstack[context.fstackPos];
                    context.fstackPos--;
                    context.pc++;
                    break;
                case localStore_string:
                    context.slocals[context.slocalsPos + grGetInstructionUnsignedValue(
                                opcode)] = context.sstack[context.sstackPos];
                    context.sstackPos--;
                    context.pc++;
                    break;
                case localStore_object:
                    context.olocals[context.olocalsPos + grGetInstructionUnsignedValue(
                                opcode)] = context.ostack[context.ostackPos];
                    context.ostackPos--;
                    context.pc++;
                    break;
                case localStore2_int:
                    context.ilocals[context.ilocalsPos + grGetInstructionUnsignedValue(
                                opcode)] = context.istack[context.istackPos];
                    context.pc++;
                    break;
                case localStore2_float:
                    context.flocals[context.flocalsPos + grGetInstructionUnsignedValue(
                                opcode)] = context.fstack[context.fstackPos];
                    context.pc++;
                    break;
                case localStore2_string:
                    context.slocals[context.slocalsPos + grGetInstructionUnsignedValue(
                                opcode)] = context.sstack[context.sstackPos];
                    context.pc++;
                    break;
                case localStore2_object:
                    context.olocals[context.olocalsPos + grGetInstructionUnsignedValue(
                                opcode)] = context.ostack[context.ostackPos];
                    context.pc++;
                    break;
                case localLoad_int:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos]
                        = context.ilocals[context.ilocalsPos + grGetInstructionUnsignedValue(
                                    opcode)];
                    context.pc++;
                    break;
                case localLoad_float:
                    context.fstackPos++;
                    if (context.fstackPos == context.fstack.length)
                        context.fstack.length *= 2;
                    context.fstack[context.fstackPos]
                        = context.flocals[context.flocalsPos + grGetInstructionUnsignedValue(
                                    opcode)];
                    context.pc++;
                    break;
                case localLoad_string:
                    context.sstackPos++;
                    if (context.sstackPos == context.sstack.length)
                        context.sstack.length *= 2;
                    context.sstack[context.sstackPos]
                        = context.slocals[context.slocalsPos + grGetInstructionUnsignedValue(
                                    opcode)];
                    context.pc++;
                    break;
                case localLoad_object:
                    context.ostackPos++;
                    if (context.ostackPos == context.ostack.length)
                        context.ostack.length *= 2;
                    context.ostack[context.ostackPos]
                        = context.olocals[context.olocalsPos + grGetInstructionUnsignedValue(
                                    opcode)];
                    context.pc++;
                    break;
                case globalStore_int:
                    _iglobals[grGetInstructionUnsignedValue(opcode)] = context
                        .istack[context.istackPos];
                    context.istackPos--;
                    context.pc++;
                    break;
                case globalStore_float:
                    _fglobals[grGetInstructionUnsignedValue(opcode)] = context
                        .fstack[context.fstackPos];
                    context.fstackPos--;
                    context.pc++;
                    break;
                case globalStore_string:
                    _sglobals[grGetInstructionUnsignedValue(opcode)] = context
                        .sstack[context.sstackPos];
                    context.sstackPos--;
                    context.pc++;
                    break;
                case globalStore_object:
                    _oglobals[grGetInstructionUnsignedValue(opcode)] = context
                        .ostack[context.ostackPos];
                    context.ostackPos--;
                    context.pc++;
                    break;
                case globalStore2_int:
                    _iglobals[grGetInstructionUnsignedValue(opcode)] = context
                        .istack[context.istackPos];
                    context.pc++;
                    break;
                case globalStore2_float:
                    _fglobals[grGetInstructionUnsignedValue(opcode)] = context
                        .fstack[context.fstackPos];
                    context.pc++;
                    break;
                case globalStore2_string:
                    _sglobals[grGetInstructionUnsignedValue(opcode)] = context
                        .sstack[context.sstackPos];
                    context.pc++;
                    break;
                case globalStore2_object:
                    _oglobals[grGetInstructionUnsignedValue(opcode)] = context
                        .ostack[context.ostackPos];
                    context.pc++;
                    break;
                case globalLoad_int:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = _iglobals[grGetInstructionUnsignedValue(
                                opcode)];
                    context.pc++;
                    break;
                case globalLoad_float:
                    context.fstackPos++;
                    if (context.fstackPos == context.fstack.length)
                        context.fstack.length *= 2;
                    context.fstack[context.fstackPos] = _fglobals[grGetInstructionUnsignedValue(
                                opcode)];
                    context.pc++;
                    break;
                case globalLoad_string:
                    context.sstackPos++;
                    if (context.sstackPos == context.sstack.length)
                        context.sstack.length *= 2;
                    context.sstack[context.sstackPos] = _sglobals[grGetInstructionUnsignedValue(
                                opcode)];
                    context.pc++;
                    break;
                case globalLoad_object:
                    context.ostackPos++;
                    if (context.ostackPos == context.ostack.length)
                        context.ostack.length *= 2;
                    context.ostack[context.ostackPos] = _oglobals[grGetInstructionUnsignedValue(
                                opcode)];
                    context.pc++;
                    break;
                case refStore_int:
                    *(cast(int*) context.ostack[context.ostackPos]) = context
                        .istack[context.istackPos];
                    context.ostackPos--;
                    context.istackPos--;
                    context.pc++;
                    break;
                case refStore_float:
                    *(cast(float*) context.ostack[context.ostackPos]) = context
                        .fstack[context.fstackPos];
                    context.ostackPos--;
                    context.fstackPos--;
                    context.pc++;
                    break;
                case refStore_string:
                    *(cast(string*) context.ostack[context.ostackPos]) = context
                        .sstack[context.sstackPos];
                    context.ostackPos--;
                    context.sstackPos--;
                    context.pc++;
                    break;
                case refStore_object:
                    *(cast(void**) context.ostack[context.ostackPos - 1]) = context
                        .ostack[context.ostackPos];
                    context.ostackPos -= 2;
                    context.pc++;
                    break;
                case refStore2_int:
                    *(cast(int*) context.ostack[context.ostackPos]) = context
                        .istack[context.istackPos];
                    context.ostackPos--;
                    context.pc++;
                    break;
                case refStore2_float:
                    *(cast(float*) context.ostack[context.ostackPos]) = context
                        .fstack[context.fstackPos];
                    context.ostackPos--;
                    context.pc++;
                    break;
                case refStore2_string:
                    *(cast(string*) context.ostack[context.ostackPos]) = context
                        .sstack[context.sstackPos];
                    context.ostackPos--;
                    context.pc++;
                    break;
                case refStore2_object:
                    *(cast(void**) context.ostack[context.ostackPos - 1]) = context
                        .ostack[context.ostackPos];
                    context.ostack[context.ostackPos - 1] = context.ostack[context.ostackPos];
                    context.ostackPos--;
                    context.pc++;
                    break;
                case fieldStore_int:
                    (cast(GrField) context.ostack[context.ostackPos]).ivalue
                        = context.istack[context.istackPos];
                    context.istackPos += grGetInstructionSignedValue(opcode);
                    context.ostackPos--;
                    context.pc++;
                    break;
                case fieldStore_float:
                    (cast(GrField) context.ostack[context.ostackPos]).fvalue
                        = context.fstack[context.fstackPos];
                    context.fstackPos += grGetInstructionSignedValue(opcode);
                    context.ostackPos--;
                    context.pc++;
                    break;
                case fieldStore_string:
                    (cast(GrField) context.ostack[context.ostackPos]).svalue
                        = context.sstack[context.sstackPos];
                    context.sstackPos += grGetInstructionSignedValue(opcode);
                    context.ostackPos--;
                    context.pc++;
                    break;
                case fieldStore_object:
                    context.ostackPos--;
                    (cast(GrField) context.ostack[context.ostackPos]).ovalue
                        = context.ostack[context.ostackPos + 1];
                    context.ostack[context.ostackPos] = context.ostack[context.ostackPos + 1];
                    context.ostackPos += grGetInstructionSignedValue(opcode);
                    context.pc++;
                    break;
                case fieldLoad:
                    if (!context.ostack[context.ostackPos]) {
                        raise(context, "NullError");
                        break;
                    }
                    context.ostack[context.ostackPos] = cast(void*)((cast(GrObject) context.ostack[context.ostackPos])
                            ._fields[grGetInstructionUnsignedValue(opcode)]);
                    context.pc++;
                    break;
                case fieldLoad2:
                    context.ostackPos++;
                    if (context.ostackPos == context.ostack.length)
                        context.ostack.length *= 2;
                    context.ostack[context.ostackPos] = cast(void*)(
                            (cast(GrObject) context.ostack[context.ostackPos - 1])
                            ._fields[grGetInstructionUnsignedValue(opcode)]);
                    context.pc++;
                    break;
                case fieldLoad_int:
                    if (!context.ostack[context.ostackPos]) {
                        raise(context, "NullError");
                        break;
                    }
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = (cast(GrObject) context.ostack[context.ostackPos])
                        ._fields[grGetInstructionUnsignedValue(opcode)].ivalue;
                    context.ostackPos--;
                    context.pc++;
                    break;
                case fieldLoad_float:
                    if (!context.ostack[context.ostackPos]) {
                        raise(context, "NullError");
                        break;
                    }
                    context.fstackPos++;
                    if (context.fstackPos == context.fstack.length)
                        context.fstack.length *= 2;
                    context.fstack[context.fstackPos] = (cast(GrObject) context.ostack[context.ostackPos])
                        ._fields[grGetInstructionUnsignedValue(opcode)].fvalue;
                    context.ostackPos--;
                    context.pc++;
                    break;
                case fieldLoad_string:
                    if (!context.ostack[context.ostackPos]) {
                        raise(context, "NullError");
                        break;
                    }
                    context.sstackPos++;
                    if (context.sstackPos == context.sstack.length)
                        context.sstack.length *= 2;
                    context.sstack[context.sstackPos] = (cast(GrObject) context.ostack[context.ostackPos])
                        ._fields[grGetInstructionUnsignedValue(opcode)].svalue;
                    context.ostackPos--;
                    context.pc++;
                    break;
                case fieldLoad_object:
                    if (!context.ostack[context.ostackPos]) {
                        raise(context, "NullError");
                        break;
                    }
                    context.ostack[context.ostackPos] = (cast(GrObject) context.ostack[context.ostackPos])
                        ._fields[grGetInstructionUnsignedValue(opcode)].ovalue;
                    context.pc++;
                    break;
                case fieldLoad2_int:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    GrField field = (cast(GrObject) context.ostack[context.ostackPos])
                        ._fields[grGetInstructionUnsignedValue(opcode)];
                    context.istack[context.istackPos] = field.ivalue;
                    context.ostack[context.ostackPos] = cast(void*) field;
                    context.pc++;
                    break;
                case fieldLoad2_float:
                    context.fstackPos++;
                    if (context.fstackPos == context.fstack.length)
                        context.fstack.length *= 2;
                    GrField field = (cast(GrObject) context.ostack[context.ostackPos])
                        ._fields[grGetInstructionUnsignedValue(opcode)];
                    context.fstack[context.fstackPos] = field.fvalue;
                    context.ostack[context.ostackPos] = cast(void*) field;
                    context.pc++;
                    break;
                case fieldLoad2_string:
                    context.sstackPos++;
                    if (context.sstackPos == context.sstack.length)
                        context.sstack.length *= 2;
                    GrField field = (cast(GrObject) context.ostack[context.ostackPos])
                        ._fields[grGetInstructionUnsignedValue(opcode)];
                    context.sstack[context.sstackPos] = field.svalue;
                    context.ostack[context.ostackPos] = cast(void*) field;
                    context.pc++;
                    break;
                case fieldLoad2_object:
                    context.ostackPos++;
                    if (context.ostackPos == context.ostack.length)
                        context.ostack.length *= 2;
                    GrField field = (cast(GrObject) context.ostack[context.ostackPos - 1])
                        ._fields[grGetInstructionUnsignedValue(opcode)];
                    context.ostack[context.ostackPos] = field.ovalue;
                    context.ostack[context.ostackPos - 1] = cast(void*) field;
                    context.pc++;
                    break;
                case const_int:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = _bytecode.iconsts[grGetInstructionUnsignedValue(
                                opcode)];
                    context.pc++;
                    break;
                case const_float:
                    context.fstackPos++;
                    if (context.fstackPos == context.fstack.length)
                        context.fstack.length *= 2;
                    context.fstack[context.fstackPos] = _bytecode.fconsts[grGetInstructionUnsignedValue(
                                opcode)];
                    context.pc++;
                    break;
                case const_bool:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = grGetInstructionUnsignedValue(opcode);
                    context.pc++;
                    break;
                case const_string:
                    context.sstackPos++;
                    if (context.sstackPos == context.sstack.length)
                        context.sstack.length *= 2;
                    context.sstack[context.sstackPos] = _bytecode.sconsts[grGetInstructionUnsignedValue(
                                opcode)];
                    context.pc++;
                    break;
                case const_meta:
                    _meta = _bytecode.sconsts[grGetInstructionUnsignedValue(opcode)];
                    context.pc++;
                    break;
                case const_null:
                    context.ostackPos++;
                    if (context.ostackPos == context.ostack.length)
                        context.ostack.length *= 2;
                    context.ostack[context.ostackPos] = null;
                    context.pc++;
                    break;
                case globalPush_int:
                    const uint nbParams = grGetInstructionUnsignedValue(opcode);
                    for (uint i = 1u; i <= nbParams; i++)
                        _iglobalStackOut ~= context.istack[(context.istackPos - nbParams) + i];
                    context.istackPos -= nbParams;
                    context.pc++;
                    break;
                case globalPush_float:
                    const uint nbParams = grGetInstructionUnsignedValue(opcode);
                    for (uint i = 1u; i <= nbParams; i++)
                        _fglobalStackOut ~= context.fstack[(context.fstackPos - nbParams) + i];
                    context.fstackPos -= nbParams;
                    context.pc++;
                    break;
                case globalPush_string:
                    const uint nbParams = grGetInstructionUnsignedValue(opcode);
                    for (uint i = 1u; i <= nbParams; i++)
                        _sglobalStackOut ~= context.sstack[(context.sstackPos - nbParams) + i];
                    context.sstackPos -= nbParams;
                    context.pc++;
                    break;
                case globalPush_object:
                    const uint nbParams = grGetInstructionUnsignedValue(opcode);
                    for (uint i = 1u; i <= nbParams; i++)
                        _oglobalStackOut ~= context.ostack[(context.ostackPos - nbParams) + i];
                    context.ostackPos -= nbParams;
                    context.pc++;
                    break;
                case globalPop_int:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = _iglobalStackIn[$ - 1];
                    _iglobalStackIn.length--;
                    context.pc++;
                    break;
                case globalPop_float:
                    context.fstackPos++;
                    if (context.fstackPos == context.fstack.length)
                        context.fstack.length *= 2;
                    context.fstack[context.fstackPos] = _fglobalStackIn[$ - 1];
                    _fglobalStackIn.length--;
                    context.pc++;
                    break;
                case globalPop_string:
                    context.sstackPos++;
                    if (context.sstackPos == context.sstack.length)
                        context.sstack.length *= 2;
                    context.sstack[context.sstackPos] = _sglobalStackIn[$ - 1];
                    _sglobalStackIn.length--;
                    context.pc++;
                    break;
                case globalPop_object:
                    context.ostackPos++;
                    if (context.ostackPos == context.ostack.length)
                        context.ostack.length *= 2;
                    context.ostack[context.ostackPos] = _oglobalStackIn[$ - 1];
                    _oglobalStackIn.length--;
                    context.pc++;
                    break;
                case equal_int:
                    context.istackPos--;
                    context.istack[context.istackPos] = context.istack[context.istackPos]
                        == context.istack[context.istackPos + 1];
                    context.pc++;
                    break;
                case equal_float:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = context.fstack[context.fstackPos - 1]
                        == context.fstack[context.fstackPos];
                    context.fstackPos -= 2;
                    context.pc++;
                    break;
                case equal_string:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = context.sstack[context.sstackPos - 1]
                        == context.sstack[context.sstackPos];
                    context.sstackPos -= 2;
                    context.pc++;
                    break;
                case notEqual_int:
                    context.istackPos--;
                    context.istack[context.istackPos] = context.istack[context.istackPos]
                        != context.istack[context.istackPos + 1];
                    context.pc++;
                    break;
                case notEqual_float:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = context.fstack[context.fstackPos - 1]
                        != context.fstack[context.fstackPos];
                    context.fstackPos -= 2;
                    context.pc++;
                    break;
                case notEqual_string:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = context.sstack[context.sstackPos - 1]
                        != context.sstack[context.sstackPos];
                    context.sstackPos -= 2;
                    context.pc++;
                    break;
                case greaterOrEqual_int:
                    context.istackPos--;
                    context.istack[context.istackPos] = context.istack[context.istackPos]
                        >= context.istack[context.istackPos + 1];
                    context.pc++;
                    break;
                case greaterOrEqual_float:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = context.fstack[context.fstackPos - 1]
                        >= context.fstack[context.fstackPos];
                    context.fstackPos -= 2;
                    context.pc++;
                    break;
                case lesserOrEqual_int:
                    context.istackPos--;
                    context.istack[context.istackPos] = context.istack[context.istackPos]
                        <= context.istack[context.istackPos + 1];
                    context.pc++;
                    break;
                case lesserOrEqual_float:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = context.fstack[context.fstackPos - 1]
                        <= context.fstack[context.fstackPos];
                    context.fstackPos -= 2;
                    context.pc++;
                    break;
                case greater_int:
                    context.istackPos--;
                    context.istack[context.istackPos] = context.istack[context.istackPos]
                        > context.istack[context.istackPos + 1];
                    context.pc++;
                    break;
                case greater_float:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = context.fstack[context.fstackPos - 1]
                        > context.fstack[context.fstackPos];
                    context.fstackPos -= 2;
                    context.pc++;
                    break;
                case lesser_int:
                    context.istackPos--;
                    context.istack[context.istackPos] = context.istack[context.istackPos]
                        < context.istack[context.istackPos + 1];
                    context.pc++;
                    break;
                case lesser_float:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = context.fstack[context.fstackPos - 1]
                        < context.fstack[context.fstackPos];
                    context.fstackPos -= 2;
                    context.pc++;
                    break;
                case isNonNull_object:
                    context.istackPos++;
                    context.istack[context.istackPos] = (context.ostack[context.ostackPos]!is null);
                    context.ostackPos--;
                    context.pc++;
                    break;
                case and_int:
                    context.istackPos--;
                    context.istack[context.istackPos] = context.istack[context.istackPos]
                        && context.istack[context.istackPos + 1];
                    context.pc++;
                    break;
                case or_int:
                    context.istackPos--;
                    context.istack[context.istackPos] = context.istack[context.istackPos]
                        || context.istack[context.istackPos + 1];
                    context.pc++;
                    break;
                case not_int:
                    context.istack[context.istackPos] = !context.istack[context.istackPos];
                    context.pc++;
                    break;
                case add_int:
                    context.istackPos--;
                    context.istack[context.istackPos] += context.istack[context.istackPos + 1];
                    context.pc++;
                    break;
                case add_float:
                    context.fstackPos--;
                    context.fstack[context.fstackPos] += context.fstack[context.fstackPos + 1];
                    context.pc++;
                    break;
                case concatenate_string:
                    context.sstackPos--;
                    context.sstack[context.sstackPos] ~= context.sstack[context.sstackPos + 1];
                    context.pc++;
                    break;
                case substract_int:
                    context.istackPos--;
                    context.istack[context.istackPos] -= context.istack[context.istackPos + 1];
                    context.pc++;
                    break;
                case substract_float:
                    context.fstackPos--;
                    context.fstack[context.fstackPos] -= context.fstack[context.fstackPos + 1];
                    context.pc++;
                    break;
                case multiply_int:
                    context.istackPos--;
                    context.istack[context.istackPos] *= context.istack[context.istackPos + 1];
                    context.pc++;
                    break;
                case multiply_float:
                    context.fstackPos--;
                    context.fstack[context.fstackPos] *= context.fstack[context.fstackPos + 1];
                    context.pc++;
                    break;
                case divide_int:
                    if (context.istack[context.istackPos] == 0) {
                        raise(context, "ZeroDivisionError");
                        break;
                    }
                    context.istackPos--;
                    context.istack[context.istackPos] /= context.istack[context.istackPos + 1];
                    context.pc++;
                    break;
                case divide_float:
                    if (context.fstack[context.fstackPos] == 0f) {
                        raise(context, "ZeroDivisionError");
                        break;
                    }
                    context.fstackPos--;
                    context.fstack[context.fstackPos] /= context.fstack[context.fstackPos + 1];
                    context.pc++;
                    break;
                case remainder_int:
                    if (context.istack[context.istackPos] == 0) {
                        raise(context, "ZeroDivisionError");
                        break;
                    }
                    context.istackPos--;
                    context.istack[context.istackPos] %= context.istack[context.istackPos + 1];
                    context.pc++;
                    break;
                case remainder_float:
                    if (context.fstack[context.fstackPos] == 0f) {
                        raise(context, "ZeroDivisionError");
                        break;
                    }
                    context.fstackPos--;
                    context.fstack[context.fstackPos] %= context.fstack[context.fstackPos + 1];
                    context.pc++;
                    break;
                case negative_int:
                    context.istack[context.istackPos] = -context.istack[context.istackPos];
                    context.pc++;
                    break;
                case negative_float:
                    context.fstack[context.fstackPos] = -context.fstack[context.fstackPos];
                    context.pc++;
                    break;
                case increment_int:
                    context.istack[context.istackPos]++;
                    context.pc++;
                    break;
                case increment_float:
                    context.fstack[context.fstackPos] += 1f;
                    context.pc++;
                    break;
                case decrement_int:
                    context.istack[context.istackPos]--;
                    context.pc++;
                    break;
                case decrement_float:
                    context.fstack[context.fstackPos] -= 1f;
                    context.pc++;
                    break;
                case copy_int:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = context.istack[context.istackPos - 1];
                    context.pc++;
                    break;
                case copy_float:
                    context.fstackPos++;
                    if (context.fstackPos == context.fstack.length)
                        context.fstack.length *= 2;
                    context.fstack[context.fstackPos] = context.fstack[context.fstackPos - 1];
                    context.pc++;
                    break;
                case copy_string:
                    context.sstackPos++;
                    if (context.sstackPos == context.sstack.length)
                        context.sstack.length *= 2;
                    context.sstack[context.sstackPos] = context.sstack[context.sstackPos - 1];
                    context.pc++;
                    break;
                case copy_object:
                    context.ostackPos++;
                    if (context.ostackPos == context.ostack.length)
                        context.ostack.length *= 2;
                    context.ostack[context.ostackPos] = context.ostack[context.ostackPos - 1];
                    context.pc++;
                    break;
                case swap_int:
                    swapAt(context.istack, context.istackPos - 1, context.istackPos);
                    context.pc++;
                    break;
                case swap_float:
                    swapAt(context.fstack, context.fstackPos - 1, context.fstackPos);
                    context.pc++;
                    break;
                case swap_string:
                    swapAt(context.sstack, context.sstackPos - 1, context.sstackPos);
                    context.pc++;
                    break;
                case swap_object:
                    swapAt(context.ostack, context.ostackPos - 1, context.ostackPos);
                    context.pc++;
                    break;
                case setupIterator:
                    if (context.istack[context.istackPos] < 0)
                        context.istack[context.istackPos] = 0;
                    context.istack[context.istackPos]++;
                    context.pc++;
                    break;
                case return_:
                    //If another task was killed by an exception,
                    //we might end up there if the task has just been spawned.
                    if (context.stackPos < 0 && context.isKilled) {
                        _contexts.markInternalForRemoval(index);
                        continue contextsLabel;
                    }
                    //Check for deferred calls.
                    else if (context.callStack[context.stackPos].deferStack.length) {
                        //Pop the last defer and run it.
                        context.pc = context.callStack[context.stackPos].deferStack[$ - 1];
                        context.callStack[context.stackPos].deferStack.length--;
                    }
                    else {
                        //Then returns to the last context.
                        context.stackPos--;
                        context.pc = context.callStack[context.stackPos].retPosition;
                        context.ilocalsPos -= context.callStack[context.stackPos].ilocalStackSize;
                        context.flocalsPos -= context.callStack[context.stackPos].flocalStackSize;
                        context.slocalsPos -= context.callStack[context.stackPos].slocalStackSize;
                        context.olocalsPos -= context.callStack[context.stackPos].olocalStackSize;
                    }
                    break;
                case unwind:
                    //If another task was killed by an exception,
                    //we might end up there if the task has just been spawned.
                    if (context.stackPos < 0) {
                        _contexts.markInternalForRemoval(index);
                        continue contextsLabel;
                    }
                    //Check for deferred calls.
                    else if (context.callStack[context.stackPos].deferStack.length) {
                        //Pop the next defer and run it.
                        context.pc = context.callStack[context.stackPos].deferStack[$ - 1];
                        context.callStack[context.stackPos].deferStack.length--;
                    }
                    else if (context.isKilled) {
                        if (context.stackPos) {
                            //Then returns to the last context without modifying the pc.
                            context.stackPos--;
                            context.ilocalsPos
                                -= context.callStack[context.stackPos].ilocalStackSize;
                            context.flocalsPos
                                -= context.callStack[context.stackPos].flocalStackSize;
                            context.slocalsPos
                                -= context.callStack[context.stackPos].slocalStackSize;
                            context.olocalsPos
                                -= context.callStack[context.stackPos].olocalStackSize;

                            if (_isDebug)
                                _debugProfileEnd();
                        }
                        else {
                            //Every deferred call has been executed, now die.
                            _contexts.markInternalForRemoval(index);
                            continue contextsLabel;
                        }
                    }
                    else if (context.isPanicking) {
                        //An exception has been raised without any try/catch inside the function.
                        //So all deferred code is run here before searching in the parent function.
                        if (context.stackPos) {
                            //Then returns to the last context without modifying the pc.
                            context.stackPos--;
                            context.ilocalsPos
                                -= context.callStack[context.stackPos].ilocalStackSize;
                            context.flocalsPos
                                -= context.callStack[context.stackPos].flocalStackSize;
                            context.slocalsPos
                                -= context.callStack[context.stackPos].slocalStackSize;
                            context.olocalsPos
                                -= context.callStack[context.stackPos].olocalStackSize;

                            if (_isDebug)
                                _debugProfileEnd();

                            //Exception handler found in the current function, just jump.
                            if (context.callStack[context.stackPos].exceptionHandlers.length) {
                                context.pc
                                    = context.callStack[context.stackPos].exceptionHandlers[$ - 1];
                            }
                        }
                        else {
                            //Kill the others.
                            foreach (coroutine; _contexts) {
                                coroutine.pc = cast(uint)(cast(int) _bytecode.opcodes.length - 1);
                                coroutine.isKilled = true;
                            }
                            _contextsToSpawn.reset();

                            //The VM is now panicking.
                            _isPanicking = true;
                            _panicMessage = _sglobalStackIn[$ - 1];
                            _sglobalStackIn.length--;

                            //Every deferred call has been executed, now die.
                            _contexts.markInternalForRemoval(index);
                            continue contextsLabel;
                        }
                    }
                    else {
                        //Then returns to the last context.
                        context.stackPos--;
                        context.pc = context.callStack[context.stackPos].retPosition;
                        context.ilocalsPos -= context.callStack[context.stackPos].ilocalStackSize;
                        context.flocalsPos -= context.callStack[context.stackPos].flocalStackSize;
                        context.slocalsPos -= context.callStack[context.stackPos].slocalStackSize;
                        context.olocalsPos -= context.callStack[context.stackPos].olocalStackSize;

                        if (_isDebug)
                            _debugProfileEnd();
                    }
                    break;
                case defer:
                    context.callStack[context.stackPos].deferStack ~= context.pc + grGetInstructionSignedValue(
                            opcode);
                    context.pc++;
                    break;
                case localStack_int:
                    const auto istackSize = grGetInstructionUnsignedValue(opcode);
                    context.callStack[context.stackPos].ilocalStackSize = istackSize;
                    if ((context.ilocalsPos + istackSize) >= context.ilocalsLimit)
                        context.doubleIntLocalsStackSize(context.ilocalsPos + istackSize);
                    context.pc++;
                    break;
                case localStack_float:
                    const auto fstackSize = grGetInstructionUnsignedValue(opcode);
                    context.callStack[context.stackPos].flocalStackSize = fstackSize;
                    if ((context.flocalsPos + fstackSize) >= context.flocalsLimit)
                        context.doubleFloatLocalsStackSize(context.flocalsPos + fstackSize);
                    context.pc++;
                    break;
                case localStack_string:
                    const auto sstackSize = grGetInstructionUnsignedValue(opcode);
                    context.callStack[context.stackPos].slocalStackSize = sstackSize;
                    if ((context.slocalsPos + sstackSize) >= context.slocalsLimit)
                        context.doubleStringLocalsStackSize(context.slocalsPos + sstackSize);
                    context.pc++;
                    break;
                case localStack_object:
                    const auto ostackSize = grGetInstructionUnsignedValue(opcode);
                    context.callStack[context.stackPos].olocalStackSize = ostackSize;
                    if ((context.olocalsPos + ostackSize) >= context.olocalsLimit)
                        context.doubleObjectLocalsStackSize(context.olocalsPos + ostackSize);
                    context.pc++;
                    break;
                case call:
                    if ((context.stackPos + 1) >= context.callStackLimit)
                        context.doubleCallStackSize();
                    context.ilocalsPos += context.callStack[context.stackPos].ilocalStackSize;
                    context.flocalsPos += context.callStack[context.stackPos].flocalStackSize;
                    context.slocalsPos += context.callStack[context.stackPos].slocalStackSize;
                    context.olocalsPos += context.callStack[context.stackPos].olocalStackSize;
                    context.callStack[context.stackPos].retPosition = context.pc + 1u;
                    context.stackPos++;
                    context.pc = grGetInstructionUnsignedValue(opcode);
                    break;
                case anonymousCall:
                    if ((context.stackPos + 1) >= context.callStackLimit)
                        context.doubleCallStackSize();
                    context.ilocalsPos += context.callStack[context.stackPos].ilocalStackSize;
                    context.flocalsPos += context.callStack[context.stackPos].flocalStackSize;
                    context.slocalsPos += context.callStack[context.stackPos].slocalStackSize;
                    context.olocalsPos += context.callStack[context.stackPos].olocalStackSize;
                    context.callStack[context.stackPos].retPosition = context.pc + 1u;
                    context.stackPos++;
                    context.pc = context.istack[context.istackPos];
                    context.istackPos--;
                    break;
                case primitiveCall:
                    _calls[grGetInstructionUnsignedValue(opcode)].call(context);
                    context.pc++;
                    break;
                case jump:
                    context.pc += grGetInstructionSignedValue(opcode);
                    break;
                case jumpEqual:
                    if (context.istack[context.istackPos])
                        context.pc++;
                    else
                        context.pc += grGetInstructionSignedValue(opcode);
                    context.istackPos--;
                    break;
                case jumpNotEqual:
                    if (context.istack[context.istackPos])
                        context.pc += grGetInstructionSignedValue(opcode);
                    else
                        context.pc++;
                    context.istackPos--;
                    break;
                case array_int:
                    GrIntArray ary = new GrIntArray;
                    const auto arySize = grGetInstructionUnsignedValue(opcode);
                    for (int i = arySize - 1; i >= 0; i--)
                        ary.data ~= context.istack[context.istackPos - i];
                    context.istackPos -= arySize;
                    context.ostackPos++;
                    if (context.ostackPos == context.ostack.length)
                        context.ostack.length *= 2;
                    context.ostack[context.ostackPos] = cast(void*) ary;
                    context.pc++;
                    break;
                case array_float:
                    GrFloatArray ary = new GrFloatArray;
                    const auto arySize = grGetInstructionUnsignedValue(opcode);
                    for (int i = arySize - 1; i >= 0; i--)
                        ary.data ~= context.fstack[context.fstackPos - i];
                    context.fstackPos -= arySize;
                    context.ostackPos++;
                    if (context.ostackPos == context.ostack.length)
                        context.ostack.length *= 2;
                    context.ostack[context.ostackPos] = cast(void*) ary;
                    context.pc++;
                    break;
                case array_string:
                    GrStringArray ary = new GrStringArray;
                    const auto arySize = grGetInstructionUnsignedValue(opcode);
                    for (int i = arySize - 1; i >= 0; i--)
                        ary.data ~= context.sstack[context.sstackPos - i];
                    context.sstackPos -= arySize;
                    context.ostackPos++;
                    if (context.ostackPos == context.ostack.length)
                        context.ostack.length *= 2;
                    context.ostack[context.ostackPos] = cast(void*) ary;
                    context.pc++;
                    break;
                case array_object:
                    GrObjectArray ary = new GrObjectArray;
                    const auto arySize = grGetInstructionUnsignedValue(opcode);
                    for (int i = arySize - 1; i >= 0; i--)
                        ary.data ~= context.ostack[context.ostackPos - i];
                    context.ostackPos -= arySize;
                    context.ostackPos++;
                    if (context.ostackPos == context.ostack.length)
                        context.ostack.length *= 2;
                    context.ostack[context.ostackPos] = cast(void*) ary;
                    context.pc++;
                    break;
                case index_int:
                    GrIntArray ary = cast(GrIntArray) context.ostack[context.ostackPos];
                    auto idx = context.istack[context.istackPos];
                    if (idx < 0) {
                        idx = (cast(int) ary.data.length) + idx;
                    }
                    if (idx >= ary.data.length) {
                        raise(context, "IndexError");
                        break;
                    }
                    context.ostack[context.ostackPos] = &ary.data[idx];
                    context.istackPos--;
                    context.pc++;
                    break;
                case index_float:
                    GrFloatArray ary = cast(GrFloatArray) context.ostack[context.ostackPos];
                    auto idx = context.istack[context.istackPos];
                    if (idx < 0) {
                        idx = (cast(int) ary.data.length) + idx;
                    }
                    if (idx >= ary.data.length) {
                        raise(context, "IndexError");
                        break;
                    }
                    context.ostack[context.ostackPos] = &ary.data[idx];
                    context.istackPos--;
                    context.pc++;
                    break;
                case index_string:
                    GrStringArray ary = cast(GrStringArray) context.ostack[context.ostackPos];
                    auto idx = context.istack[context.istackPos];
                    if (idx < 0) {
                        idx = (cast(int) ary.data.length) + idx;
                    }
                    if (idx >= ary.data.length) {
                        raise(context, "IndexError");
                        break;
                    }
                    context.ostack[context.ostackPos] = &ary.data[idx];
                    context.istackPos--;
                    context.pc++;
                    break;
                case index_object:
                    GrObjectArray ary = cast(GrObjectArray) context.ostack[context.ostackPos];
                    auto idx = context.istack[context.istackPos];
                    if (idx < 0) {
                        idx = (cast(int) ary.data.length) + idx;
                    }
                    if (idx >= ary.data.length) {
                        raise(context, "IndexError");
                        break;
                    }
                    context.ostack[context.ostackPos] = &ary.data[idx];
                    context.istackPos--;
                    context.pc++;
                    break;
                case index2_int:
                    GrIntArray ary = cast(GrIntArray) context.ostack[context.ostackPos];
                    auto idx = context.istack[context.istackPos];
                    if (idx < 0) {
                        idx = (cast(int) ary.data.length) + idx;
                    }
                    if (idx >= ary.data.length) {
                        raise(context, "IndexError");
                        break;
                    }
                    context.istack[context.istackPos] = ary.data[idx];
                    context.ostackPos--;
                    context.pc++;
                    break;
                case index2_float:
                    GrFloatArray ary = cast(GrFloatArray) context.ostack[context.ostackPos];
                    auto idx = context.istack[context.istackPos];
                    if (idx < 0) {
                        idx = (cast(int) ary.data.length) + idx;
                    }
                    if (idx >= ary.data.length) {
                        raise(context, "IndexError");
                        break;
                    }
                    context.fstackPos++;
                    if (context.fstackPos == context.fstack.length)
                        context.fstack.length *= 2;
                    context.istackPos--;
                    context.ostackPos--;
                    context.fstack[context.fstackPos] = ary.data[idx];
                    context.pc++;
                    break;
                case index2_string:
                    GrStringArray ary = cast(GrStringArray) context.ostack[context.ostackPos];
                    auto idx = context.istack[context.istackPos];
                    if (idx < 0) {
                        idx = (cast(int) ary.data.length) + idx;
                    }
                    if (idx >= ary.data.length) {
                        raise(context, "IndexError");
                        break;
                    }
                    context.sstackPos++;
                    if (context.sstackPos == context.sstack.length)
                        context.sstack.length *= 2;
                    context.istackPos--;
                    context.ostackPos--;
                    context.sstack[context.sstackPos] = ary.data[idx];
                    context.pc++;
                    break;
                case index2_object:
                    GrObjectArray ary = cast(GrObjectArray) context.ostack[context.ostackPos];
                    auto idx = context.istack[context.istackPos];
                    if (idx < 0) {
                        idx = (cast(int) ary.data.length) + idx;
                    }
                    if (idx >= ary.data.length) {
                        raise(context, "IndexError");
                        break;
                    }
                    context.istackPos--;
                    context.ostack[context.ostackPos] = ary.data[idx];
                    context.pc++;
                    break;
                case index3_int:
                    GrIntArray ary = cast(GrIntArray) context.ostack[context.ostackPos];
                    auto idx = context.istack[context.istackPos];
                    if (idx < 0) {
                        idx = (cast(int) ary.data.length) + idx;
                    }
                    if (idx >= ary.data.length) {
                        raise(context, "IndexError");
                        break;
                    }
                    context.istack[context.istackPos] = ary.data[idx];
                    context.ostack[context.ostackPos] = &ary.data[idx];
                    context.pc++;
                    break;
                case index3_float:
                    GrFloatArray ary = cast(GrFloatArray) context.ostack[context.ostackPos];
                    auto idx = context.istack[context.istackPos];
                    if (idx < 0) {
                        idx = (cast(int) ary.data.length) + idx;
                    }
                    if (idx >= ary.data.length) {
                        raise(context, "IndexError");
                        break;
                    }
                    context.istackPos--;
                    context.fstackPos++;
                    context.fstack[context.fstackPos] = ary.data[idx];
                    context.ostack[context.ostackPos] = &ary.data[idx];
                    context.pc++;
                    break;
                case index3_string:
                    GrStringArray ary = cast(GrStringArray) context.ostack[context.ostackPos];
                    auto idx = context.istack[context.istackPos];
                    if (idx < 0) {
                        idx = (cast(int) ary.data.length) + idx;
                    }
                    if (idx >= ary.data.length) {
                        raise(context, "IndexError");
                        break;
                    }
                    context.istackPos--;
                    context.sstackPos++;
                    context.sstack[context.sstackPos] = ary.data[idx];
                    context.ostack[context.ostackPos] = &ary.data[idx];
                    context.pc++;
                    break;
                case index3_object:
                    GrObjectArray ary = cast(GrObjectArray) context.ostack[context.ostackPos];
                    auto idx = context.istack[context.istackPos];
                    if (idx < 0) {
                        idx = (cast(int) ary.data.length) + idx;
                    }
                    if (idx >= ary.data.length) {
                        raise(context, "IndexError");
                        break;
                    }
                    context.istackPos--;
                    context.ostack[context.ostackPos] = &ary.data[idx];
                    context.ostackPos++;
                    context.ostack[context.ostackPos] = ary.data[idx];
                    context.pc++;
                    break;
                case length_int:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = cast(int)(
                            (cast(GrIntArray) context.ostack[context.ostackPos]).data.length);
                    context.ostackPos--;
                    context.pc++;
                    break;
                case length_float:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = cast(int)(
                            (cast(GrFloatArray) context.ostack[context.ostackPos]).data.length);
                    context.ostackPos--;
                    context.pc++;
                    break;
                case length_string:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = cast(int)(
                            (cast(GrStringArray) context.ostack[context.ostackPos]).data.length);
                    context.ostackPos--;
                    context.pc++;
                    break;
                case length_object:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = cast(int)(
                            (cast(GrObjectArray) context.ostack[context.ostackPos]).data.length);
                    context.ostackPos--;
                    context.pc++;
                    break;
                case concatenate_intArray:
                    GrIntArray nArray = new GrIntArray;
                    context.ostackPos--;
                    nArray.data = (cast(GrIntArray) context.ostack[context.ostackPos])
                        .data ~ (cast(GrIntArray) context.ostack[context.ostackPos + 1]).data;
                    context.ostack[context.ostackPos] = cast(void*) nArray;
                    context.pc++;
                    break;
                case concatenate_floatArray:
                    GrFloatArray nArray = new GrFloatArray;
                    context.ostackPos--;
                    nArray.data = (cast(GrFloatArray) context.ostack[context.ostackPos])
                        .data ~ (cast(GrFloatArray) context.ostack[context.ostackPos + 1]).data;
                    context.ostack[context.ostackPos] = cast(void*) nArray;
                    context.pc++;
                    break;
                case concatenate_stringArray:
                    GrStringArray nArray = new GrStringArray;
                    context.ostackPos--;
                    nArray.data = (cast(GrStringArray) context.ostack[context.ostackPos])
                        .data ~ (cast(GrStringArray) context.ostack[context.ostackPos + 1]).data;
                    context.ostack[context.ostackPos] = cast(void*) nArray;
                    context.pc++;
                    break;
                case concatenate_objectArray:
                    GrObjectArray nArray = new GrObjectArray;
                    context.ostackPos--;
                    nArray.data = (cast(GrObjectArray) context.ostack[context.ostackPos])
                        .data ~ (cast(GrObjectArray) context.ostack[context.ostackPos + 1]).data;
                    context.ostack[context.ostackPos] = cast(void*) nArray;
                    context.pc++;
                    break;
                case append_int:
                    GrIntArray nArray = new GrIntArray;
                    nArray.data = (cast(GrIntArray) context.ostack[context.ostackPos])
                        .data ~ context.istack[context.istackPos];
                    context.ostack[context.ostackPos] = cast(void*) nArray;
                    context.istackPos--;
                    context.pc++;
                    break;
                case append_float:
                    GrFloatArray nArray = new GrFloatArray;
                    nArray.data = (cast(GrFloatArray) context.ostack[context.ostackPos])
                        .data ~ context.fstack[context.fstackPos];
                    context.ostack[context.ostackPos] = cast(void*) nArray;
                    context.fstackPos--;
                    context.pc++;
                    break;
                case append_string:
                    GrStringArray nArray = new GrStringArray;
                    nArray.data = (cast(GrStringArray) context.ostack[context.ostackPos])
                        .data ~ context.sstack[context.sstackPos];
                    context.ostack[context.ostackPos] = cast(void*) nArray;
                    context.sstackPos--;
                    context.pc++;
                    break;
                case append_object:
                    GrObjectArray nArray = new GrObjectArray;
                    context.ostackPos--;
                    nArray.data = (cast(GrObjectArray) context.ostack[context.ostackPos])
                        .data ~ context.ostack[context.ostackPos + 1];
                    context.ostack[context.ostackPos] = cast(void*) nArray;
                    context.pc++;
                    break;
                case prepend_int:
                    GrIntArray nArray = new GrIntArray;
                    nArray.data = context.istack[context.istackPos] ~ (
                            cast(GrIntArray) context.ostack[context.ostackPos]).data;
                    context.ostack[context.ostackPos] = cast(void*) nArray;
                    context.istackPos--;
                    context.pc++;
                    break;
                case prepend_float:
                    GrFloatArray nArray = new GrFloatArray;
                    nArray.data = context.fstack[context.fstackPos] ~ (
                            cast(GrFloatArray) context.ostack[context.ostackPos]).data;
                    context.ostack[context.ostackPos] = cast(void*) nArray;
                    context.fstackPos--;
                    context.pc++;
                    break;
                case prepend_string:
                    GrStringArray nArray = new GrStringArray;
                    nArray.data = context.sstack[context.sstackPos] ~ (
                            cast(GrStringArray) context.ostack[context.ostackPos]).data;
                    context.ostack[context.ostackPos] = cast(void*) nArray;
                    context.sstackPos--;
                    context.pc++;
                    break;
                case prepend_object:
                    GrObjectArray nArray = new GrObjectArray;
                    context.ostackPos--;
                    nArray.data = context.ostack[context.ostackPos] ~ (cast(
                            GrObjectArray) context.ostack[context.ostackPos + 1]).data;
                    context.ostack[context.ostackPos] = cast(void*) nArray;
                    context.pc++;
                    break;
                case equal_intArray:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = (cast(GrIntArray) context.ostack[context.ostackPos - 1])
                        .data == (cast(GrIntArray) context.ostack[context.ostackPos]).data;
                    context.ostackPos -= 2;
                    context.pc++;
                    break;
                case equal_floatArray:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = (cast(GrFloatArray) context.ostack[context.ostackPos - 1])
                        .data == (cast(GrFloatArray) context.ostack[context.ostackPos]).data;
                    context.ostackPos -= 2;
                    context.pc++;
                    break;
                case equal_stringArray:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = (cast(GrStringArray) context.ostack[context.ostackPos - 1])
                        .data == (cast(GrStringArray) context.ostack[context.ostackPos]).data;
                    context.ostackPos -= 2;
                    context.pc++;
                    break;
                case notEqual_intArray:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = (cast(GrIntArray) context.ostack[context.ostackPos - 1])
                        .data != (cast(GrIntArray) context.ostack[context.ostackPos]).data;
                    context.ostackPos -= 2;
                    context.pc++;
                    break;
                case notEqual_floatArray:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = (cast(GrFloatArray) context.ostack[context.ostackPos - 1])
                        .data != (cast(GrFloatArray) context.ostack[context.ostackPos]).data;
                    context.ostackPos -= 2;
                    context.pc++;
                    break;
                case notEqual_stringArray:
                    context.istackPos++;
                    if (context.istackPos == context.istack.length)
                        context.istack.length *= 2;
                    context.istack[context.istackPos] = (cast(GrStringArray) context.ostack[context.ostackPos - 1])
                        .data != (cast(GrStringArray) context.ostack[context.ostackPos]).data;
                    context.ostackPos -= 2;
                    context.pc++;
                    break;
                case debugProfileBegin:
                    _debugProfileBegin(opcode, context.pc);
                    context.pc++;
                    break;
                case debugProfileEnd:
                    _debugProfileEnd();
                    context.pc++;
                    break;
                }
            }
        }
        _contexts.sweepMarkedData();
    }

    /// Create a new object.
    GrObject createObject(string name) {
        int index;
        for (; index < _bytecode.classes.length; index++) {
            if (name == _bytecode.classes[index].name)
                return new GrObject(_bytecode.classes[index]);
        }
        return null;
    }

    import core.time : MonoTime, Duration;

    private {
        bool _isDebug;
        DebugFunction[int] _debugFunctions;
        DebugFunction[] _debugFunctionsStack;
    }

    /// Runtime information about every called functions
    DebugFunction[int] dumpProfiling() {
        return _debugFunctions;
    }

    /// Prettify the result from `dumpProfiling`
    string prettifyProfiling() {
        import std.algorithm.comparison : max;
        import std.conv : to;

        string report;
        ulong functionNameLength = 10;
        ulong countLength = 10;
        ulong totalLength = 10;
        ulong averageLength = 10;
        foreach (func; dumpProfiling()) {
            functionNameLength = max(func.name.length, functionNameLength);
            countLength = max(to!string(func.count).length, countLength);
            totalLength = max(to!string(func.total.total!"msecs").length, totalLength);
            Duration average = func.count ? (func.total / func.count) : Duration.zero;
            averageLength = max(to!string(average.total!"msecs").length, averageLength);
        }
        string header = "| " ~ leftJustify("Function", functionNameLength) ~ " | " ~ leftJustify("Count",
                countLength) ~ " | " ~ leftJustify("Total",
                totalLength) ~ " | " ~ leftJustify("Average", averageLength) ~ " |";

        string separator = "+" ~ leftJustify("", functionNameLength + 2,
                '-') ~ "+" ~ leftJustify("", countLength + 2, '-') ~ "+" ~ leftJustify("",
                totalLength + 2, '-') ~ "+" ~ leftJustify("", averageLength + 2, '-') ~ "+";
        report ~= separator ~ "\n" ~ header ~ "\n" ~ separator ~ "\n";
        foreach (func; dumpProfiling()) {
            Duration average = func.count ? (func.total / func.count) : Duration.zero;
            report ~= "| " ~ leftJustify(func.name, functionNameLength) ~ " | " ~ leftJustify(
                    to!string(func.count), countLength) ~ " | " ~ leftJustify(to!string(func.total.total!"msecs"),
                    totalLength) ~ " | " ~ leftJustify(to!string(average.total!"msecs"),
                    averageLength) ~ " |\n";
        }
        report ~= separator ~ "\n";
        return report;
    }

    /// Runtime information of a called function
    final class DebugFunction {
        private {
            MonoTime _start;
            Duration _total;
            ulong _count;
            int _pc;
            string _name;
        }

        @property {
            /// Total execution time passed inside the function
            Duration total() const {
                return _total;
            }
            /// Total times the function was called
            ulong count() const {
                return _count;
            }
            /// Prettified name of the function
            string name() const {
                return _name;
            }
        }
    }

    private void _debugProfileEnd() {
        if (!_debugFunctionsStack.length)
            return;
        auto p = _debugFunctionsStack[$ - 1];
        _debugFunctionsStack.length--;
        p._total += MonoTime.currTime() - p._start;
        p._count++;
    }

    private void _debugProfileBegin(uint opcode, int pc) {
        _isDebug = true;
        auto p = (pc in _debugFunctions);
        if (p) {
            p._start = MonoTime.currTime();
            _debugFunctionsStack ~= *p;
        }
        else {
            auto debugFunc = new DebugFunction;
            debugFunc._pc = pc;
            debugFunc._name = _bytecode.sconsts[grGetInstructionUnsignedValue(opcode)];
            debugFunc._start = MonoTime.currTime();
            _debugFunctions[pc] = debugFunc;
            _debugFunctionsStack ~= debugFunc;
        }
    }
}

///Temp
/*void raiseDump(GrContext context) {
    import std.stdio: writeln;
    writeln("error raised at: ", context.pc);
    for (int i = context.stackPos - 1; i >= 0; i --) {
        writeln("at: ", context.callStack[i].retPosition);
    }
}*/