import { i18n } from "discourse-i18n";
import BtcpayCheckout from "../components/btcpay-checkout";
import BtcpaySubscriptionStatus from "../components/btcpay-subscription-status";

export default <template>
  <div class="btcpay-subscribe-page">
    <h1>{{i18n "btcpay.subscribe.title"}}</h1>
    <p class="btcpay-subscribe-intro">{{i18n "btcpay.subscribe.intro"}}</p>

    <BtcpayCheckout />
    <BtcpaySubscriptionStatus />
  </div>
</template>
