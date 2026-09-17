import BtcpayCheckout from "../components/btcpay-checkout";
import BtcpayPageHeader from "../components/btcpay-page-header";
import BtcpaySubscriptionStatus from "../components/btcpay-subscription-status";

export default <template>
  <div class="btcpay-page btcpay-tickets-page">
    <BtcpayPageHeader @page="tickets" />
    <BtcpayCheckout />
    <BtcpaySubscriptionStatus />
  </div>
</template>
