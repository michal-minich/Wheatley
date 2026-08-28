import { ChatApp } from "./app/ChatApp";
import { configuredWheatleyEndpoint } from "./transport/WheatleyEndpoint";
import { H } from "./ui/h";

const app = new ChatApp(H.single("#app"), configuredWheatleyEndpoint());
void app.start();
