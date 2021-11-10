import { legendsminter } from "../../declarations/legendsminter";

document.getElementById("clickMeBtn").addEventListener("click", async () => {
  const name = document.getElementById("name").value.toString();
  // Interact with legendsminter actor, calling the greet method
  const greeting = await legendsminter.greet(name);

  document.getElementById("greeting").innerText = greeting;
});
