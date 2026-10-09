package com.abdoyasser.wallet;

import org.springframework.boot.SpringApplication;

public class TestWalletApplication {

	public static void main(String[] args) {
		SpringApplication.from(WalletApplication::main).with(TestcontainersConfiguration.class).run(args);
	}

}
