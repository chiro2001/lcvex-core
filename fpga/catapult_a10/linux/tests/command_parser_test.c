#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum command_id {
	CMD_EMPTY = 0,
	CMD_HELP = 1,
	CMD_ECHO = 2,
	CMD_SLEEP = 3,
	CMD_ABOUT = 4,
	CMD_UNKNOWN = 5,
};

extern int lcvex_parse_command(const char *line, size_t length,
			       const char **payload, size_t *payload_length);
extern int lcvex_line_event(unsigned int byte, uint32_t *skip_lf);

static int check_command(const char *line, int expected_command,
			 const char *expected_payload)
{
	const char *payload = NULL;
	size_t payload_length = 0;
	int command = lcvex_parse_command(line, strlen(line), &payload,
					  &payload_length);
	size_t expected_length = strlen(expected_payload);

	if (command != expected_command || payload_length != expected_length ||
	    memcmp(payload, expected_payload, expected_length) != 0) {
		fprintf(stderr,
			"parse(%s): command=%d payload='%.*s' length=%zu; expected command=%d payload='%s'\n",
			line, command, (int)payload_length, payload,
			payload_length, expected_command, expected_payload);
		return 1;
	}
	return 0;
}

static int check_line_event(unsigned int byte, uint32_t *skip_lf,
			    int expected_event, uint32_t expected_state)
{
	int event = lcvex_line_event(byte, skip_lf);

	if (event != expected_event || *skip_lf != expected_state) {
		fprintf(stderr,
			"line_event(0x%x): event=%d state=%u; expected event=%d state=%u\n",
			byte, event, *skip_lf, expected_event, expected_state);
		return 1;
	}
	return 0;
}

int main(void)
{
	int failures = 0;
	uint32_t skip_lf = 0;

	failures += check_command("help", CMD_HELP, "help");
	failures += check_command("  help \t", CMD_HELP, "help");
	failures += check_command("echo hello world", CMD_ECHO, "hello world");
	failures += check_command("echo   alpha  beta  ", CMD_ECHO,
			   "alpha  beta");
	failures += check_command("echo", CMD_ECHO, "");
	failures += check_command("sleep", CMD_SLEEP, "sleep");
	failures += check_command("about", CMD_ABOUT, "about");
	failures += check_command("", CMD_EMPTY, "");
	failures += check_command(" \t ", CMD_EMPTY, "");
	failures += check_command("helper", CMD_UNKNOWN, "helper");
	failures += check_command("echoX", CMD_UNKNOWN, "echoX");
	failures += check_command("reboot", CMD_UNKNOWN, "reboot");

	/* CR ends a line, a following LF is swallowed, and LF also works alone. */
	failures += check_line_event('\r', &skip_lf, 1, 1);
	failures += check_line_event('\n', &skip_lf, 2, 0);
	failures += check_line_event('\n', &skip_lf, 1, 0);
	failures += check_line_event('\r', &skip_lf, 1, 1);
	failures += check_line_event('h', &skip_lf, 0, 0);
	failures += check_line_event('\r', &skip_lf, 1, 1);
	failures += check_line_event('\r', &skip_lf, 1, 1);
	failures += check_line_event('\n', &skip_lf, 2, 0);

	if (failures != 0)
		return 1;
	puts("PASS: Catapult /init command parser and CR/LF handling");
	return 0;
}
