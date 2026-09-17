import BtcpayPageHeader from "../components/btcpay-page-header";
import BtcpaySubscriptionStatus from "../components/btcpay-subscription-status";

export default <template>
  <div class="btcpay-page btcpay-billing-page">
    <BtcpayPageHeader @page="billing" />
    <BtcpaySubscriptionStatus />
  </div>
</template>
