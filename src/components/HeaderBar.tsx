import Image from 'next/image';
import React from 'react';
import logo from '../../public/assets/Logo.png';

function HeaderBar() {
  const menuItems = ['Buy', 'Sell', 'Rent', 'Moretgage', 'Blog'];
  return (
    <section>
      <div className="flex justify-between items-center mx-4 py-2">
        <div className="logos-outer">
          <Image src={logo} alt="Logo" />
        </div>
        <div className="menus-outer">
          <nav >
            <ul className='flex gap-4'>
              {menuItems.map((item, index) => (
                <li key={index}>{item}</li>
              ))}
            </ul>
          </nav>
        </div>
        <div className="actions-outer flex gap-4">
        <button>List Your Home</button>
        <button>Sign In</button>
        </div>
      </div>
    </section>
  );
}

export default HeaderBar;
