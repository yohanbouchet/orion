package com.openclassroom.devops.orion.microcrm;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.SpringBootTest.WebEnvironment;
import org.springframework.boot.test.web.server.LocalManagementPort;
import org.springframework.boot.test.web.server.LocalServerPort;

// Supervision (ticket #84) : métriques et santé sur le port de gestion
// seulement ; l'API ne publie aucun point /actuator
@SpringBootTest(webEnvironment = WebEnvironment.RANDOM_PORT,
		properties = "management.server.port=0")
class ManagementEndpointsTest {

	private final HttpClient client = HttpClient.newHttpClient();

	@LocalServerPort
	private int apiPort;

	@LocalManagementPort
	private int managementPort;

	private HttpResponse<String> get(int port, String path)
			throws IOException, InterruptedException {
		HttpRequest request = HttpRequest
				.newBuilder(URI.create("http://127.0.0.1:" + port + path))
				.GET()
				.build();
		return client.send(request, HttpResponse.BodyHandlers.ofString());
	}

	@Test
	void prometheusMetricsArePublishedOnTheManagementPort() throws Exception {
		get(apiPort, "/persons");

		HttpResponse<String> response = get(managementPort, "/actuator/prometheus");

		assertThat(response.statusCode()).isEqualTo(200);
		assertThat(response.body()).contains("http_server_requests_seconds_bucket");
	}

	@Test
	void healthIsPublishedOnTheManagementPort() throws Exception {
		HttpResponse<String> response = get(managementPort, "/actuator/health");

		assertThat(response.statusCode()).isEqualTo(200);
		assertThat(response.body()).contains("\"status\":\"UP\"");
	}

	@Test
	void apiPortDoesNotExposeActuator() throws Exception {
		assertThat(get(apiPort, "/actuator/prometheus").statusCode()).isEqualTo(404);
		assertThat(get(apiPort, "/actuator/health").statusCode()).isEqualTo(404);
	}

	@Test
	void onlyHealthAndPrometheusAreExposed() throws Exception {
		assertThat(get(managementPort, "/actuator/env").statusCode()).isEqualTo(404);
		assertThat(get(managementPort, "/actuator/beans").statusCode()).isEqualTo(404);
	}

}
