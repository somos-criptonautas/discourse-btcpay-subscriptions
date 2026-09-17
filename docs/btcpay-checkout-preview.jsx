import { useState } from "react";

const plans = [
  {
    plan_id: "premium-monthly",
    label: "Premium Monthly",
    price: "10.00",
    currency: "USD",
    interval: "month",
    group: "premium",
  },
  {
    plan_id: "premium-yearly",
    label: "Premium Yearly",
    price: "99.00",
    currency: "USD",
    interval: "year",
    group: "premium",
  },
];

const stripeProducts = [
  { name: "Premium Monthly", price: "$10.00/month", id: 1 },
  { name: "Premium Yearly", price: "$99.00/year", id: 2 },
];

function StripeSection() {
  const [selected, setSelected] = useState(null);
  return (
    <div style={styles.section}>
      <div style={styles.sectionHeader}>
        <div style={styles.sectionIcon}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#635bff" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"><path d="M21 4H3c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h18c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2z"/><line x1="1" y1="10" x2="23" y2="10"/></svg>
        </div>
        <h3 style={styles.sectionTitle}>Pay with Card</h3>
        <span style={styles.poweredBy}>Stripe</span>
      </div>
      <div style={styles.planList}>
        {stripeProducts.map((p) => (
          <label
            key={p.id}
            style={{
              ...styles.planOption,
              ...(selected === p.id ? styles.planSelected : {}),
            }}
            onClick={() => setSelected(p.id)}
          >
            <div style={styles.radioOuter}>
              {selected === p.id && <div style={styles.radioInnerStripe} />}
            </div>
            <div style={styles.planInfo}>
              <span style={styles.planName}>{p.name}</span>
              <span style={styles.planPrice}>{p.price}</span>
            </div>
          </label>
        ))}
      </div>
      <button
        style={{
          ...styles.btn,
          ...styles.btnStripe,
          ...(selected ? {} : styles.btnDisabled),
        }}
      >
        Subscribe with Card
      </button>
    </div>
  );
}

function BtcpaySection() {
  const [selected, setSelected] = useState(null);
  const [loading, setLoading] = useState(false);
  const [redirecting, setRedirecting] = useState(false);

  const handleCheckout = () => {
    if (!selected) return;
    setLoading(true);
    setTimeout(() => {
      setLoading(false);
      setRedirecting(true);
      setTimeout(() => setRedirecting(false), 3000);
    }, 1200);
  };

  return (
    <div style={styles.section}>
      <div style={styles.sectionHeader}>
        <div style={{ ...styles.sectionIcon, background: "rgba(247,147,26,0.1)" }}>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="#f7931a">
            <path d="M23.638 14.904c-1.602 6.43-8.113 10.34-14.542 8.736C2.67 22.05-1.244 15.525.362 9.105 1.962 2.67 8.475-1.243 14.9.358c6.43 1.605 10.342 8.115 8.738 14.546zm-6.35-4.613c.24-1.59-.974-2.45-2.634-3.02l.54-2.153-1.315-.33-.524 2.084c-.346-.086-.7-.167-1.053-.254l.529-2.09L11.512 5l-.539 2.16c-.285-.065-.565-.13-.837-.195l.001-.009-1.815-.454-.35 1.407s.975.224.955.238c.535.136.63.49.614.773l-.614 2.456c.037.009.085.023.14.043l-.14-.036-.86 3.44c-.064.16-.228.4-.6.31.015.02-.956-.239-.956-.239L4.83 16.24l1.713.427c.318.08.63.163.937.24l-.544 2.19 1.313.328.54-2.17c.36.1.708.19 1.05.273l-.538 2.156 1.316.33.545-2.19c2.24.424 3.926.253 4.635-1.774.572-1.634-.028-2.58-1.21-3.196.86-.198 1.508-.766 1.681-1.934zm-3.01 4.22c-.404 1.64-3.157.75-4.05.53l.72-2.9c.896.224 3.757.67 3.33 2.37zm.41-4.24c-.37 1.49-2.662.734-3.405.548l.654-2.63c.744.186 3.137.534 2.75 2.082z"/>
          </svg>
        </div>
        <h3 style={styles.sectionTitle}>Pay with crypto</h3>
        <span style={{ ...styles.poweredBy, color: "#f7931a" }}>BTCPay Server</span>
      </div>

      {redirecting ? (
        <div style={styles.redirectNotice}>
          <div style={styles.spinner} />
          <span>Redirecting to BTCPay checkout...</span>
        </div>
      ) : (
        <>
          <div style={styles.planList}>
            {plans.map((p) => (
              <label
                key={p.plan_id}
                style={{
                  ...styles.planOption,
                  ...(selected === p.plan_id ? styles.planSelectedBtc : {}),
                }}
                onClick={() => setSelected(p.plan_id)}
              >
                <div style={styles.radioOuter}>
                  {selected === p.plan_id && <div style={styles.radioInnerBtc} />}
                </div>
                <div style={styles.planInfo}>
                  <span style={styles.planName}>{p.label}</span>
                  <span style={styles.planPrice}>
                    ${p.price}/{p.interval === "month" ? "mo" : "yr"}
                  </span>
                </div>
                <div style={styles.cryptoBadges}>
                  <span style={styles.badge}>BTC</span>
                  <span style={styles.badge}>Lightning</span>
                  <span style={{ ...styles.badge, background: "rgba(255,106,0,0.08)", color: "#ff6a00" }}>XMR</span>
                </div>
              </label>
            ))}
          </div>
          <button
            style={{
              ...styles.btn,
              ...styles.btnBtc,
              ...(selected && !loading ? {} : styles.btnDisabled),
            }}
            onClick={handleCheckout}
          >
            {loading ? (
              <span style={{ display: "flex", alignItems: "center", gap: 8, justifyContent: "center" }}>
                <div style={{ ...styles.spinnerSmall }} />
                Creating checkout...
              </span>
            ) : (
              "Pay with crypto"
            )}
          </button>
          <p style={styles.hint}>
            You'll be redirected to BTCPay Server to complete payment
          </p>
        </>
      )}
    </div>
  );
}

function UserBillingPreview() {
  const [tab, setTab] = useState("active");

  return (
    <div style={styles.billingCard}>
      <div style={styles.billingHeader}>
        <h3 style={styles.billingTitle}>My Bitcoin Subscription</h3>
        <span style={styles.activeBadge}>Active</span>
      </div>
      <div style={styles.billingGrid}>
        <div style={styles.billingRow}>
          <span style={styles.billingLabel}>Plan</span>
          <span style={styles.billingValue}>Premium Monthly</span>
        </div>
        <div style={styles.billingRow}>
          <span style={styles.billingLabel}>Current period ends</span>
          <span style={styles.billingValue}>April 4, 2026</span>
        </div>
        <div style={styles.billingRow}>
          <span style={styles.billingLabel}>Payment method</span>
          <span style={styles.billingValue}>Bitcoin (Lightning)</span>
        </div>
      </div>
      <div style={styles.billingActions}>
        <button style={{ ...styles.btn, ...styles.btnSmall, background: "#2d2d2d", color: "#fff" }}>
          Manage on BTCPay ↗
        </button>
      </div>

      <div style={styles.paymentsSection}>
        <h4 style={styles.paymentsTitle}>Payment History</h4>
        <table style={styles.table}>
          <thead>
            <tr>
              <th style={styles.th}>Date</th>
              <th style={styles.th}>Amount</th>
              <th style={styles.th}>Method</th>
              <th style={styles.th}>Status</th>
            </tr>
          </thead>
          <tbody>
            {[
              { date: "Mar 4, 2026", amount: "$10.00", method: "Lightning", status: "settled" },
              { date: "Feb 4, 2026", amount: "$10.00", method: "BTC on-chain", status: "settled" },
              { date: "Jan 4, 2026", amount: "$10.00", method: "Lightning", status: "settled" },
            ].map((p, i) => (
              <tr key={i}>
                <td style={styles.td}>{p.date}</td>
                <td style={styles.td}>{p.amount}</td>
                <td style={styles.td}>{p.method}</td>
                <td style={styles.td}>
                  <span style={styles.settledBadge}>{p.status}</span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

export default function App() {
  const [view, setView] = useState("checkout");

  return (
    <div style={styles.page}>
      <style>{`
        @import url('https://fonts.bunny.net/css?family=source-sans-3:400,500,600,700&display=swap');
        * { box-sizing: border-box; margin: 0; padding: 0; }
        @keyframes spin { to { transform: rotate(360deg); } }
      `}</style>

      <div style={styles.container}>
        <div style={styles.topBar}>
          <div style={styles.discourseLogo}>
            <svg width="24" height="24" viewBox="0 0 24 24" fill="#222"><circle cx="12" cy="12" r="11" fill="#222"/><text x="12" y="16" textAnchor="middle" fill="#fff" fontSize="12" fontWeight="700">d</text></svg>
            <span style={styles.forumName}>Your Forum</span>
          </div>
          <div style={styles.tabs}>
            <button
              style={{ ...styles.tab, ...(view === "checkout" ? styles.tabActive : {}) }}
              onClick={() => setView("checkout")}
            >
              Subscribe
            </button>
            <button
              style={{ ...styles.tab, ...(view === "billing" ? styles.tabActive : {}) }}
              onClick={() => setView("billing")}
            >
              My Billing
            </button>
          </div>
        </div>

        {view === "checkout" ? (
          <div style={styles.content}>
            <h2 style={styles.pageTitle}>Choose a subscription</h2>
            <p style={styles.pageDesc}>
              Subscribe to unlock premium categories and features
            </p>

            <div style={styles.columns}>
              <StripeSection />
              <div style={styles.divider}>
                <span style={styles.dividerText}>or</span>
              </div>
              <BtcpaySection />
            </div>
          </div>
        ) : (
          <div style={styles.content}>
            <UserBillingPreview />
          </div>
        )}
      </div>
    </div>
  );
}

const styles = {
  page: {
    minHeight: "100vh",
    background: "#f4f5f7",
    fontFamily: "'Source Sans 3', -apple-system, sans-serif",
    color: "#1a1a1a",
    padding: "24px 16px",
  },
  container: {
    maxWidth: 840,
    margin: "0 auto",
    background: "#fff",
    borderRadius: 12,
    boxShadow: "0 1px 3px rgba(0,0,0,0.06), 0 4px 16px rgba(0,0,0,0.04)",
    overflow: "hidden",
  },
  topBar: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    padding: "16px 28px",
    borderBottom: "1px solid #e9ecef",
  },
  discourseLogo: {
    display: "flex",
    alignItems: "center",
    gap: 10,
  },
  forumName: {
    fontWeight: 700,
    fontSize: 16,
    color: "#222",
  },
  tabs: {
    display: "flex",
    gap: 4,
  },
  tab: {
    padding: "8px 18px",
    borderRadius: 8,
    border: "none",
    background: "transparent",
    fontSize: 14,
    fontWeight: 600,
    color: "#666",
    cursor: "pointer",
    fontFamily: "inherit",
    transition: "all 0.15s",
  },
  tabActive: {
    background: "#f0f0f0",
    color: "#1a1a1a",
  },
  content: {
    padding: "32px 28px 40px",
  },
  pageTitle: {
    fontSize: 24,
    fontWeight: 700,
    marginBottom: 6,
    letterSpacing: "-0.02em",
  },
  pageDesc: {
    fontSize: 15,
    color: "#666",
    marginBottom: 28,
  },
  columns: {
    display: "flex",
    gap: 0,
    alignItems: "stretch",
  },
  divider: {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    padding: "0 20px",
    position: "relative",
  },
  dividerText: {
    fontSize: 13,
    color: "#aaa",
    fontWeight: 600,
    textTransform: "uppercase",
    letterSpacing: "0.05em",
    background: "#fff",
    padding: "8px 0",
    zIndex: 1,
  },
  section: {
    flex: 1,
    padding: "24px",
    border: "1px solid #e9ecef",
    borderRadius: 10,
    background: "#fafbfc",
  },
  sectionHeader: {
    display: "flex",
    alignItems: "center",
    gap: 10,
    marginBottom: 20,
  },
  sectionIcon: {
    width: 36,
    height: 36,
    borderRadius: 8,
    background: "rgba(99,91,255,0.08)",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
  },
  sectionTitle: {
    fontSize: 16,
    fontWeight: 700,
    flex: 1,
    letterSpacing: "-0.01em",
  },
  poweredBy: {
    fontSize: 11,
    fontWeight: 600,
    color: "#635bff",
    textTransform: "uppercase",
    letterSpacing: "0.04em",
  },
  planList: {
    display: "flex",
    flexDirection: "column",
    gap: 8,
    marginBottom: 16,
  },
  planOption: {
    display: "flex",
    alignItems: "center",
    gap: 12,
    padding: "14px 16px",
    border: "1.5px solid #e2e5e9",
    borderRadius: 8,
    cursor: "pointer",
    transition: "all 0.15s",
    background: "#fff",
  },
  planSelected: {
    borderColor: "#635bff",
    background: "rgba(99,91,255,0.02)",
    boxShadow: "0 0 0 1px #635bff",
  },
  planSelectedBtc: {
    borderColor: "#f7931a",
    background: "rgba(247,147,26,0.02)",
    boxShadow: "0 0 0 1px #f7931a",
  },
  radioOuter: {
    width: 18,
    height: 18,
    borderRadius: "50%",
    border: "2px solid #ccc",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
  },
  radioInnerStripe: {
    width: 10,
    height: 10,
    borderRadius: "50%",
    background: "#635bff",
  },
  radioInnerBtc: {
    width: 10,
    height: 10,
    borderRadius: "50%",
    background: "#f7931a",
  },
  planInfo: {
    display: "flex",
    flexDirection: "column",
    gap: 2,
    flex: 1,
  },
  planName: {
    fontSize: 14,
    fontWeight: 600,
  },
  planPrice: {
    fontSize: 13,
    color: "#888",
  },
  cryptoBadges: {
    display: "flex",
    gap: 4,
  },
  badge: {
    fontSize: 10,
    fontWeight: 700,
    padding: "3px 7px",
    borderRadius: 4,
    background: "rgba(247,147,26,0.08)",
    color: "#f7931a",
    letterSpacing: "0.02em",
  },
  btn: {
    width: "100%",
    padding: "12px 20px",
    borderRadius: 8,
    border: "none",
    fontSize: 14,
    fontWeight: 700,
    cursor: "pointer",
    fontFamily: "inherit",
    transition: "all 0.15s",
    letterSpacing: "-0.01em",
  },
  btnStripe: {
    background: "#635bff",
    color: "#fff",
  },
  btnBtc: {
    background: "#f7931a",
    color: "#fff",
  },
  btnDisabled: {
    opacity: 0.45,
    cursor: "not-allowed",
  },
  btnSmall: {
    width: "auto",
    padding: "8px 16px",
    fontSize: 13,
    borderRadius: 6,
  },
  hint: {
    fontSize: 12,
    color: "#999",
    textAlign: "center",
    marginTop: 10,
  },
  redirectNotice: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    gap: 12,
    padding: "40px 20px",
    fontSize: 14,
    color: "#666",
    fontWeight: 500,
  },
  spinner: {
    width: 22,
    height: 22,
    border: "3px solid #e9ecef",
    borderTopColor: "#f7931a",
    borderRadius: "50%",
    animation: "spin 0.7s linear infinite",
  },
  spinnerSmall: {
    width: 16,
    height: 16,
    border: "2px solid rgba(255,255,255,0.3)",
    borderTopColor: "#fff",
    borderRadius: "50%",
    animation: "spin 0.7s linear infinite",
  },

  // Billing page
  billingCard: {
    border: "1px solid #e9ecef",
    borderRadius: 10,
    overflow: "hidden",
  },
  billingHeader: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    padding: "20px 24px",
    borderBottom: "1px solid #e9ecef",
    background: "#fafbfc",
  },
  billingTitle: {
    fontSize: 17,
    fontWeight: 700,
  },
  activeBadge: {
    fontSize: 12,
    fontWeight: 700,
    padding: "4px 10px",
    borderRadius: 6,
    background: "rgba(34,197,94,0.1)",
    color: "#16a34a",
  },
  billingGrid: {
    padding: "20px 24px",
    display: "flex",
    flexDirection: "column",
    gap: 14,
  },
  billingRow: {
    display: "flex",
    justifyContent: "space-between",
    alignItems: "center",
  },
  billingLabel: {
    fontSize: 14,
    color: "#888",
  },
  billingValue: {
    fontSize: 14,
    fontWeight: 600,
  },
  billingActions: {
    padding: "0 24px 20px",
  },
  paymentsSection: {
    borderTop: "1px solid #e9ecef",
    padding: "20px 24px",
  },
  paymentsTitle: {
    fontSize: 15,
    fontWeight: 700,
    marginBottom: 14,
  },
  table: {
    width: "100%",
    borderCollapse: "collapse",
  },
  th: {
    textAlign: "left",
    fontSize: 12,
    fontWeight: 600,
    color: "#999",
    padding: "8px 12px",
    borderBottom: "1px solid #e9ecef",
    textTransform: "uppercase",
    letterSpacing: "0.04em",
  },
  td: {
    fontSize: 13,
    padding: "10px 12px",
    borderBottom: "1px solid #f3f4f6",
  },
  settledBadge: {
    fontSize: 11,
    fontWeight: 700,
    padding: "2px 8px",
    borderRadius: 4,
    background: "rgba(34,197,94,0.1)",
    color: "#16a34a",
  },
};
