#!/bin/bash

# Check github connection stable or not:
check_connection() {
	# Just check if we can reach GitHub API
	if curl -s --max-time 5 -o /dev/null "https://api.github.com"; then
		echo "internet_error=0" >>"$GITHUB_OUTPUT"
		echo -e "\e[32mGithub connection OK\e[0m"
	else
		echo "internet_error=1" >>"$GITHUB_OUTPUT"
		echo -e "\e[31mGithub connection not stable!\e[0m"
	fi
}
check_connection
