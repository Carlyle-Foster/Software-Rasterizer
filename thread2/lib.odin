package thread2

import "base:runtime"
import "base:intrinsics"

import "core:log"
import "core:mem"
import "core:thread"

_ :: log
_ :: mem

Thread :: thread.Thread
Thread_Priority :: thread.Thread_Priority

MAX_USER_ARGUMENTS :: 8

/*
Run a procedure with two polymorphic parameters on a different thread.

This procedure runs the given procedure on another thread. The context
specified by `init_context` will be used as the context in which `fn` is going
to execute. The thread will have priority specified by the `priority` parameter.

If `self_cleanup` is specified, after the thread finishes the execution of the
`fn` procedure, the resources associated with the thread are going to be
automatically freed. **Do not** dereference the `^Thread` pointer, if this
flag is specified.

**IMPORTANT**: If `init_context` is specified and the default temporary allocator
is used, the thread procedure needs to call `runtime.default_temp_allocator_destroy()`
in order to free the resources associated with the temporary allocations.
*/
create_and_start_with_poly_data2 :: proc(arg1: $T1, arg2: $T2, fn: proc(T1, T2), init_context: Maybe(runtime.Context) = nil, priority := Thread_Priority.Normal, self_cleanup := false) -> ^Thread
	where size_of(T1) + size_of(T2) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	thread_proc :: proc(t: ^Thread) {
		fn := cast(proc(T1, T2))t.data
		assert(t.user_index >= 2)
		
		user_args := mem.slice_to_bytes(t.user_args[:])
		arg1 := (^T1)(raw_data(user_args))^
		arg2 := (^T2)(raw_data(user_args[size_of(T1):]))^

		fn(arg1, arg2)
	}
	t := thread.create(thread_proc, priority)
	t.data = rawptr(fn)
	t.user_index = 2

	arg1, arg2 := arg1, arg2
	user_args := mem.slice_to_bytes(t.user_args[:])

	n := copy(user_args,     mem.ptr_to_bytes(&arg1))
	_  = copy(user_args[n:], mem.ptr_to_bytes(&arg2))

	if self_cleanup {
		intrinsics.atomic_or(&t.flags, {.Self_Cleanup})
	}

	t.init_context = init_context
	thread.start(t)

	// log.info("started thread")
	
	return t
}
