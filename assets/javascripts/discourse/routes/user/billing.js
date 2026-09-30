import Route from "@ember/routing/route";
import { service } from "@ember/service";

export default class UserBillingRoute extends Route {
  @service currentUser;
  @service router;

  templateName = "user/billing";

  // The endpoint always answers for the viewer, so someone else's profile must
  // never render this tab — it would show your own billing under their name.
  beforeModel() {
    if (this.currentUser?.id !== this.modelFor("user").id) {
      this.router.replaceWith("userActivity");
    }
  }
}
