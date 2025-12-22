
// iorpio syscalls

[CCode (cprefix = "", lower_case_cprefix = "")]
namespace IoPrio {
	[CCode (cheader_filename = "unistd.h", sentinel = "", feature_test_macro = "_DEFAULT_SOURCE")]
	extern long syscall (long number, ...);

	[CCode (cheader_filename = "sys/syscall.h")]
	public const int SYS_ioprio_get;

	[CCode (cheader_filename = "sys/syscall.h")]
	public const int SYS_ioprio_set;

	[CCode (cheader_filename = "linux/ioprio.h")]
	public const int IOPRIO_WHO_PROCESS;

	[CCode (cheader_filename = "linux/ioprio.h", cname = "int", cprefix = "IOPRIO_CLASS_")]
	public enum PrioClass {
		NONE,
		RT,
		BE,
		IDLE,
		INVALID,
	}

	/*
		construct a prio value using a PrioClass and a class specific data attribute
		See man 2 ioprio_set for details
	 */
	[CCode (cheader_filename = "linux/ioprio.h", cname = "IOPRIO_PRIO_VALUE")]
	extern int prioValue(PrioClass clas, int data);
}
